#!/usr/bin/env bash
#
# copilot-review-bot.sh — poll GitHub pull requests and request (or re-request)
# a GitHub Copilot code review when one is due.
#
# Designed to run from cron/systemd every ~15 minutes on a machine that can
# only make outbound HTTPS connections (e.g. a Google Cloud VM with no inbound
# firewall rules). There is no webhook receiver and no inbound port: every run
# is a fresh poll of the current state of each repo.
#
# ---------------------------------------------------------------------------
# What it does, per open PR
# ---------------------------------------------------------------------------
#
#  A. Mentions (any open PR, including drafts and non-default base branches)
#     A comment (PR conversation comment or review comment) that mentions
#     @xrplf-bot triggers a Copilot review request, unless Copilot has already
#     reviewed the current head commit, or a Copilot review request is already
#     pending on the PR. The bot then reacts to the triggering comment:
#       +1    (THUMBS_UP)   review requested successfully
#       -1    (THUMBS_DOWN) request failed — the error is also posted as a
#                           PR comment so the code/message is visible
#       eyes  (EYES)        acknowledged, nothing to do (Copilot already
#                           reviewed the head commit, or a request is pending)
#     The reaction *is* the "already handled" bookkeeping: any comment that
#     already carries one of those three reactions from this bot account is
#     skipped on later runs. No local database is needed, so the state
#     survives VM rebuilds and works if you run more than one instance.
#
#  B. Automatic review requests (non-draft PRs targeting the base branch only)
#     1. Copilot has never reviewed the PR                       -> request.
#     2. Copilot has reviewed before                             -> request only if
#        - every review thread opened by Copilot is resolved, AND
#        - at least one non-merge commit has landed on the head branch since
#          the commit Copilot last reviewed.
#        A plain merge commit from the base branch (branch refresh) therefore
#        does NOT trigger a new review; any other commit does.
#     A request is skipped while a Copilot review request is already pending,
#     and a local marker prevents re-requesting twice for the same head commit.
#
# ---------------------------------------------------------------------------
# Requirements
# ---------------------------------------------------------------------------
#   bash 4.4+ (macOS ships 3.2 — use a newer one from Homebrew), gh (GitHub
#   CLI), jq, flock (util-linux; `brew install flock` on macOS), and either GNU
#   or BSD date. All of this is verified before any work starts.
#   Auth: GH_TOKEN or GITHUB_TOKEN in the environment (gh picks either up).
#
#   Token permissions:
#     - Fine-grained PAT: Pull requests -> Read and write (Metadata: Read is
#       attached automatically). Contents -> Read is recommended so commit
#       parents can be read on private repos.
#     - Classic PAT: `repo` (or `public_repo` for public repos only).
#     - GitHub App installation token: Pull requests: write.
#   The account behind the token also needs at least the Triage repo role —
#   the same floor GitHub requires to request a review from a human
#   collaborator, because Copilot occupies the same "Reviewers" slot. A
#   read-only token is enough to read PRs but the requestReviews mutation 403s.
#   Separately, Copilot must have a license/seat enabled for the repo or the
#   request is filed but never acted on.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   copilot-review-bot.sh [options] [owner/name ...]
#
#   -r, --repo owner/name     Repo to monitor (repeatable). May also be given
#                             as bare positional arguments, or in $REPOS
#                             (whitespace separated).
#       --base BRANCH         Base branch to gate automatic requests on.
#                             Default: each repo's own default branch.
#       --pr N                Only look at this PR number (debugging).
#       --bot-id NODE_ID      Copilot's Bot node id, skips discovery.
#       --handle NAME         Mention handle without '@'. Default: xrplf-bot.
#       --mention-age DAYS    Ignore mention comments older than this.
#                             Default: 7. Keeps a first run from replying to
#                             years of history.
#       --max-requests N      Stop after N review requests in one run.
#                             Default: 25. Guards against a storm on day one
#                             and against GitHub's secondary rate limits.
#       --ignore-outdated     Treat outdated (code-has-since-changed) Copilot
#                             threads as if they were resolved.
#   -n, --dry-run             Report what would happen; make no changes.
#   -v, --verbose             Log every PR, including the skipped ones.
#       --explain FILE        Debug: run the decision logic over a saved
#                             pullRequest JSON object and print the result.
#   -h, --help                This text.
#
# Exit status: 0 all good, 1 one or more PRs hit an error, 2 fatal/usage.
#
# The jq programs below (JQ_LIB, JQ_DECIDE, ...) are single-quoted on
# purpose, so the shell leaves them untouched; only jq's own $vars, passed
# in via --argjson/--arg, are meant to expand.
# shellcheck disable=SC2016
set -euo pipefail

VERSION="1.0.0"
ACTION="requested" # reworded under --dry-run

# ---------------------------------------------------------------------------
# Configuration (all overridable by environment)
# ---------------------------------------------------------------------------

# Logins Copilot's review bot has been seen to use, lowercased. Compared
# case-insensitively against review authors / requested reviewers.
COPILOT_LOGINS="${COPILOT_LOGINS:-}"
[[ -z "${COPILOT_LOGINS}" ]] && COPILOT_LOGINS='["copilot-pull-request-reviewer","copilot","github-copilot"]'

# Copilot's Bot node id is global to github.com, so it is cached across runs.
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/copilot-review-bot}"
BOT_ID_CACHE="${BOT_ID_CACHE:-${STATE_DIR}/copilot-bot-id}"
LOCK_FILE="${LOCK_FILE:-${STATE_DIR}/lock}"

# Last-resort fallback if discovery finds nothing (see discover_bot_id). This
# is Copilot's well-known Bot node id on github.com; it is only a hint, and
# using it logs a warning. Set USE_BOT_ID_HINT=false to disable.
COPILOT_BOT_ID_HINT="${COPILOT_BOT_ID_HINT:-BOT_kgDOC9w8XQ}"
USE_BOT_ID_HINT="${USE_BOT_ID_HINT:-true}"

MENTION_HANDLE="${MENTION_HANDLE:-xrplf-bot}"
MENTION_MAX_AGE_DAYS="${MENTION_MAX_AGE_DAYS:-7}"
MAX_REQUESTS_PER_RUN="${MAX_REQUESTS_PER_RUN:-25}"
MAX_PRS_PER_REPO="${MAX_PRS_PER_REPO:-300}"
IGNORE_OUTDATED="${IGNORE_OUTDATED:-false}"

# What to do when the branch was force-pushed after a Copilot review and no
# commit on it was authored after that review — a restack or an amend, with
# nothing in the metadata to tell them apart. false waits for a commit that is
# demonstrably new work (anyone can still ask with an @mention); true treats any
# rewrite as new work, which re-reviews on every rebase.
REWRITE_TRIGGERS_REVIEW="${REWRITE_TRIGGERS_REVIEW:-false}"
SLEEP_BETWEEN_MUTATIONS="${SLEEP_BETWEEN_MUTATIONS:-1}"

# Heartbeat interval, in PRs, for non-verbose runs. 0 disables it. Verbose runs
# log every PR anyway and skip this.
PROGRESS_EVERY="${PROGRESS_EVERY:-25}"

repos=()
base_override=""
only_pr=""
bot_id="${COPILOT_BOT_ID:-}"
dry_run=false
verbose=false
explain_file=""
exit_status=0
requests_made=0
viewer=""

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
# Falls back to a bare '-' if date is unavailable, so preflight can still
# report a missing coreutils cleanly instead of drowning in its own errors.
timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf -- '-'; }
log() { printf '%s %s\n' "$(timestamp)" "$*"; }
warn() { log "WARN  $*" >&2; }
err() { log "ERROR $*" >&2; }
vlog() { [[ "${verbose}" == true ]] && log "      $*" || true; }
die() {
    err "$*"
    exit 2
}
usage() {
    sed -n '/^# Usage/,/^# Exit status/p' "$0" | sed 's/^#\ \?//'
    exit "${1:-2}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r | --repo)
            repos+=("$2")
            shift 2
            ;;
        --base)
            base_override="$2"
            shift 2
            ;;
        --pr)
            only_pr="$2"
            shift 2
            ;;
        --bot-id)
            bot_id="$2"
            shift 2
            ;;
        --handle)
            MENTION_HANDLE="$2"
            shift 2
            ;;
        --mention-age)
            MENTION_MAX_AGE_DAYS="$2"
            shift 2
            ;;
        --max-requests)
            MAX_REQUESTS_PER_RUN="$2"
            shift 2
            ;;
        --ignore-outdated)
            IGNORE_OUTDATED=true
            shift
            ;;
        -n | --dry-run)
            dry_run=true
            shift
            ;;
        -v | --verbose)
            verbose=true
            shift
            ;;
        --explain)
            explain_file="$2"
            shift 2
            ;;
        --version)
            echo "copilot-review-bot.sh ${VERSION}"
            exit 0
            ;;
        -h | --help) usage 0 ;;
        -*) die "unknown option: $1" ;;
        *)
            repos+=("$1")
            shift
            ;;
    esac
done

# ---------------------------------------------------------------------------
# jq programs
# ---------------------------------------------------------------------------
# Shared definitions. $copilots is the lowercased login list.
JQ_LIB='
def is_copilot:
    if . == null then false
    else (ascii_downcase) as $l | ($copilots | index($l)) != null
    end;

def is_marked:
    (.reactionGroups // [])
    | any(.viewerHasReacted == true
          and (.content == "THUMBS_UP" or .content == "THUMBS_DOWN" or .content == "EYES"));

def unquoted:
    (.body // "") | split("\n") | map(select(startswith(">") | not)) | join("\n");

def mentions_bot:
    unquoted | test("@" + $handle + "(?![A-Za-z0-9_-])"; "i");
'

# Reduce one pullRequest object to a single tab-separated decision record.
#
# Fields: id  number  is_draft  base_ref  head_oid  has_review  pending
#         unresolved  reviewed_head  new_work  last_review_at
#
# "new_work" is the interesting one. Preferred method is positional: find the
# commit Copilot last reviewed in the PR's commit list and ask whether anything
# after it is a non-merge commit (parents == 1). If that commit is no longer in
# the list — force-push, rebase, squash — fall back to comparing committer
# dates against the review timestamp.
JQ_DECIDE="${JQ_LIB}"'
. as $pr
| (($pr.reviews.nodes // []) | map(select(.author.login | is_copilot))) as $creviews
| ($creviews | sort_by(.submittedAt // "") | last) as $lastr
| ($lastr.submittedAt // "") as $rtime
| ($lastr.commit.oid // "") as $roid
| (($pr.reviewRequests.nodes // []) | any((.requestedReviewer.login? // null) | is_copilot)) as $pending
| (($pr.commits.nodes // [])
   | map({ oid: .commit.oid,
           merge: ((.commit.parents.totalCount // 1) > 1),
           authored: (.commit.authoredDate // ""),
           committed: (.commit.committedDate // "") })) as $commits
| (($pr.reviewThreads.nodes // [])
   | map(select(((.comments.nodes[0].author.login?) // null) | is_copilot))) as $cthreads
| ($cthreads
   | map(select(.isResolved != true
                and (if $ignore_outdated then .isOutdated != true else true end)))
   | length) as $unresolved
| (($lastr != null) and ($roid == $pr.headRefOid)) as $reviewed_head

# Where the reviewed commit sits in the current commit list. Present means the
# branch was appended to and the question is exact; absent means it was
# rewritten (force push, rebase, squash, amend) and the answer is inferred.
| ($commits | map(.oid) | index($roid)) as $idx

# Candidate new work. With the anchor present, everything after it. Without it,
# commits *authored* after the review — committer dates are useless here,
# because a rebase stamps every commit with the time of the rebase, which made
# the commit Copilot had already reviewed look brand new.
| (if $lastr == null then []
   elif $idx != null then ($commits[($idx + 1):] | map(select(.merge | not)))
   else ($commits | map(select((.merge | not) and (.authored > $rtime))))
   end) as $new

| (if $lastr == null then "no-review"
   elif $idx != null then "position"
   elif ($new | length) > 0 then "authored"
   elif (($commits | any(.merge | not)) and ($roid != $pr.headRefOid)) then "rewritten"
   else "none"
   end) as $basis

# "rewritten" is the genuinely ambiguous case: the branch was rewritten but
# nothing on it was authored after the review, so this is a rebase or an amend
# and there is no way to tell which from the metadata alone.
| (if $lastr == null then false
   elif $basis == "rewritten" then $rewrite_triggers
   else (($new | length) > 0)
   end) as $new_work

| [ $pr.id,
    ($pr.number | tostring),
    (if $pr.isDraft then "1" else "0" end),
    ($pr.baseRefName // ""),
    ($pr.headRefOid // ""),
    (if $lastr == null then "0" else "1" end),
    (if $pending then "1" else "0" end),
    ($cthreads | length | tostring),
    ($unresolved | tostring),
    (if $reviewed_head then "1" else "0" end),
    (if $new_work then "1" else "0" end),
    $basis,
    ($new | length | tostring),
    (($new | last | .oid) // "-"),
    (($new | last | .authored) // "-"),
    (if $rtime == "" then "-" else $rtime end),
    (if $roid == "" then "-" else $roid end) ]
| @tsv
'

# Emit one line per unhandled @handle mention: id, kind, createdAt, author.
# Quoted lines (starting with ">") do not count, so quoting somebody else's
# request does not re-trigger it. Comments already carrying one of this
# account's marker reactions, comments by this account, and comments older
# than $since are dropped.
JQ_MENTIONS="${JQ_LIB}"'
[ ((.comments.nodes // []) | map(. + { kind: "comment" })),
  ([ (.reviewThreads.nodes // [])[] | (.comments.nodes // [])[] ] | map(. + { kind: "review-comment" })) ]
| add // []
| map(select((.createdAt // "") >= $since))
| map(select(((.author.login) // "") != $viewer))
| map(select(mentions_bot))
| map(select(is_marked | not))
| .[]
| [ .id, .kind, (.createdAt // ""), ((.author.login) // "?") ]
| @tsv
'

jq_args=(
    --argjson copilots "${COPILOT_LOGINS}"
    --argjson ignore_outdated "${IGNORE_OUTDATED}"
    --argjson rewrite_triggers "${REWRITE_TRIGGERS_REVIEW}"
    --arg handle "${MENTION_HANDLE}"
)

# ---------------------------------------------------------------------------
# GraphQL documents
# ---------------------------------------------------------------------------
Q_REPO_PRS='
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    defaultBranchRef { name }
    pullRequests(states: OPEN, first: 100, after: $cursor,
                 orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes { number }
    }
  }
}'

# Everything needed to decide about one PR, in a single round trip.
Q_PR='
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
      number
      url
      isDraft
      baseRefName
      headRefOid
      author { login }
      reviewRequests(first: 25) {
        nodes {
          requestedReviewer {
            __typename
            ... on Bot { id login }
            ... on User { login }
          }
        }
      }
      reviews(last: 100) {
        nodes {
          state
          submittedAt
          author { login ... on Bot { id } }
          commit { oid }
        }
      }
      reviewThreads(first: 100) {
        nodes {
          isResolved
          isOutdated
          comments(first: 20) {
            nodes {
              id
              createdAt
              body
              author { login }
              reactionGroups { content viewerHasReacted }
            }
          }
        }
      }
      comments(last: 100) {
        nodes {
          id
          createdAt
          body
          author { login }
          reactionGroups { content viewerHasReacted }
        }
      }
      commits(last: 100) {
        nodes {
          commit {
            oid
            # authoredDate is when the work was written; committedDate is when
            # it was last rewritten. A rebase moves the latter and leaves the
            # former alone, which is what makes "is this new work?" answerable
            # after a force push.
            authoredDate
            committedDate
            parents { totalCount }
          }
        }
      }
    }
  }
}'

M_REQUEST_REVIEW='
mutation($prId: ID!, $botId: ID!) {
  requestReviews(input: {pullRequestId: $prId, botIds: [$botId], union: true}) {
    pullRequest { number }
  }
}'

M_ADD_REACTION='
mutation($subjectId: ID!, $content: ReactionContent!) {
  addReaction(input: {subjectId: $subjectId, content: $content}) {
    reaction { content }
  }
}'

M_ADD_COMMENT='
mutation($subjectId: ID!, $body: String!) {
  addComment(input: {subjectId: $subjectId, body: $body}) {
    clientMutationId
  }
}'

Q_BOT_ID_SCAN='
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviews(last: 20) { nodes { author { login ... on Bot { id } } } }
    }
  }
}'

# ---------------------------------------------------------------------------
# GitHub helpers
# ---------------------------------------------------------------------------
# Read queries are wrapped in $( ) so their stdout can be captured, which means
# they run in a subshell and any variable they set is lost on return. Error text
# therefore goes through a file as well: set_last_error writes both, last_error
# reads whichever survived. Without this, every failed read reported a blank
# reason.
#
# The file wins when both are present: it is unconditionally overwritten on
# every call, in-subshell or not, so it is always the freshest error. LAST_ERROR
# only helps before ERR_FILE exists (there is no run directory yet), or for a
# mutation, which never runs in a subshell and so can rely on the variable
# directly. Checking LAST_ERROR first would report a stale mutation failure for
# every unrelated read failure that came after it in the same run.
LAST_ERROR=""
ERR_FILE=""

set_last_error() {
    LAST_ERROR="$1"
    [[ -n "${ERR_FILE}" ]] && printf '%s' "$1" >"${ERR_FILE}"
    return 0
}

last_error() {
    if [[ -n "${ERR_FILE}" && -s "${ERR_FILE}" ]]; then
        cat "${ERR_FILE}"
    elif [[ -n "${LAST_ERROR}" ]]; then
        printf '%s' "${LAST_ERROR}"
    fi
}

# A 4xx other than 429 will not fix itself, so retrying just burns 9 seconds
# and muddies the log.
is_retryable() { # <raw-error>
    if grep -qE 'HTTP 429|rate limit|secondary' <<<"$1"; then
        return 0
    fi
    if grep -qE 'HTTP 4[0-9]{2}' <<<"$1"; then
        return 1
    fi
    return 0
}

# Read-only query with a small retry, since a cron job should ride out a
# blip rather than skip a cycle.
gql() {
    local query="$1"
    shift
    local attempt=1 out
    while :; do
        if out="$(gh api graphql -f query="${query}" "$@" 2>&1)"; then
            printf '%s' "${out}"
            return 0
        fi
        [[ "${verbose}" == true ]] && printf 'gh: %s\n' "${out}" >&2
        if ((attempt >= 3)) || ! is_retryable "${out}"; then
            set_last_error "${out}"
            return 1
        fi
        sleep $((attempt * 3))
        attempt=$((attempt + 1))
    done
}

# Mutations are not retried: a partial success would double-post.
gql_mutate() {
    local query="$1"
    shift
    local out
    if out="$(gh api graphql -f query="${query}" "$@" 2>&1)"; then
        set_last_error ""
        return 0
    fi
    set_last_error "${out}"
    return 1
}

# Squeeze a gh/GraphQL failure into one line, keeping any status code or
# error type so it can be reported back on the PR.
error_summary() {
    local raw="$1" code
    code="$(grep -oE 'HTTP [0-9]{3}|FORBIDDEN|UNAUTHORIZED|NOT_FOUND|INSUFFICIENT_SCOPES|SAML_ENFORCED|RATE_LIMITED|MAX_NODE_LIMIT_EXCEEDED' <<<"${raw}" | head -1 || true)"
    raw="$(tr '\n' ' ' <<<"${raw}" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    raw="${raw:0:400}"
    if [[ -n "${code}" ]]; then
        printf '%s: %s' "${code}" "${raw}"
    else
        printf '%s' "${raw}"
    fi
}

# Called when a repository read fails, to turn a bare status code into
# something actionable. Two independent signals: the shape of the token (a
# fine-grained PAT is deny-by-default, which surprises people on public repos)
# and whether the repo reads fine with no credentials at all.
diagnose_access() { # <owner> <name> <raw-error>
    local owner="$1" name="$2" raw="$3" token="" fine_grained=false anon=""

    token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    [[ "${token}" == github_pat_* ]] && fine_grained=true

    if grep -qiE 'HTTP 401|bad credentials' <<<"${raw}"; then
        err "the token was rejected outright: expired, revoked, or mistyped." \
            "Check it with: gh api user"
        return
    fi
    if grep -qiE 'saml|single.sign.on' <<<"${raw}"; then
        err "the token needs SSO authorisation for the ${owner} organisation;" \
            "authorise it on the token's own settings page."
        return
    fi
    grep -qiE 'HTTP 403|HTTP 404|not accessible|forbidden|could not resolve to a repository' \
        <<<"${raw}" || return 0

    err "the token authenticated (as a valid account) but cannot read" \
        "${owner}/${name}. Note that GitHub answers 404 rather than 403 for" \
        "repositories a token has no visibility into, so either code means the" \
        "same thing here."

    if [[ "${fine_grained}" == true ]]; then
        err "the token looks like a fine-grained PAT (github_pat_...), which is" \
            "deny-by-default: it can only see repositories it was explicitly" \
            "granted, and that includes public ones. An anonymous client can" \
            "read a public repo where this token cannot. Fixes: re-create it" \
            "selecting 'Public Repositories (read-only)'; or have it granted" \
            "${owner}/${name}, which requires the ${owner} organisation to allow" \
            "fine-grained tokens and an org owner to approve the request; or" \
            "use a classic PAT with the 'repo' scope. Filing review requests" \
            "additionally needs Pull requests: Read and write plus at least" \
            "the Triage role on the repo, so read-only access is not enough."
        return
    fi

    # Not obviously a fine-grained PAT — fall back to comparing against what an
    # anonymous client sees. Inconclusive if unauthenticated calls are
    # themselves being rate limited (60/hour per IP).
    if command -v curl >/dev/null 2>&1; then
        anon="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' \
            -H 'Accept: application/vnd.github+json' \
            "https://api.github.com/repos/${owner}/${name}" 2>/dev/null || true)"
    fi
    case "${anon}" in
        200) err "${owner}/${name} reads fine with no credentials at all, so this is" \
            "the token's permissions, not the repo or the network." ;;
        404) err "${owner}/${name} is not readable anonymously either — check the" \
            "spelling, or the repo is private and the token lacks access." ;;
        *) vlog "anonymous read probe was inconclusive (status ${anon:-none})" ;;
    esac
}

# ---------------------------------------------------------------------------
# Copilot bot node id
# ---------------------------------------------------------------------------
# GitHub's REST "request reviewers" endpoint refuses bot accounts ("Reviews may
# only be requested from collaborators"), so requests go through the GraphQL
# requestReviews mutation with botIds — which needs Copilot's Bot node id.
# There is no lookup-by-login query for bots, so the id is scavenged from any
# PR where Copilot has already reviewed or been requested, then cached.
harvest_bot_id() { # <pr-json-file>
    [[ -n "${bot_id}" ]] && return 0
    local found
    found="$(jq -r "${jq_args[@]}" "${JQ_LIB}"'
        [ ((.reviews.nodes // [])[] | select(.author.login | is_copilot) | .author.id),
          ((.reviewRequests.nodes // [])[]
             | select((.requestedReviewer.login? // null) | is_copilot)
             | .requestedReviewer.id) ]
        | map(select(. != null)) | first // empty' "$1" 2>/dev/null || true)"
    if [[ -n "${found}" ]]; then
        bot_id="${found}"
        cache_bot_id "${found}"
        vlog "discovered Copilot bot id ${found}"
    fi
}

cache_bot_id() {
    mkdir -p "$(dirname "${BOT_ID_CACHE}")"
    printf '%s\n' "$1" >"${BOT_ID_CACHE}"
}

load_cached_bot_id() {
    [[ -n "${bot_id}" ]] && return 0
    if [[ -s "${BOT_ID_CACHE}" ]]; then
        bot_id="$(tr -d '[:space:]' <"${BOT_ID_CACHE}")"
        [[ -n "${bot_id}" ]] && vlog "using cached Copilot bot id ${bot_id}"
    fi
    return 0
}

# Fallback: walk recent PRs of any state looking for a Copilot review.
scan_bot_id() { # <owner> <name>
    [[ -n "${bot_id}" ]] && return 0
    local owner="$1" name="$2" numbers n found
    numbers="$(gh pr list --repo "${owner}/${name}" --state all --limit 40 \
        --json number --jq '.[].number' 2>/dev/null || true)"
    for n in ${numbers}; do
        found="$(gql "${Q_BOT_ID_SCAN}" -f owner="${owner}" -f name="${name}" -F number="${n}" \
            2>/dev/null |
            jq -r "${jq_args[@]}" "${JQ_LIB}"'
                     [ (.data.repository.pullRequest.reviews.nodes // [])[]
                       | select(.author.login | is_copilot) | .author.id ]
                     | map(select(. != null)) | first // empty' 2>/dev/null || true)"
        if [[ -n "${found}" ]]; then
            bot_id="${found}"
            cache_bot_id "${found}"
            log "discovered Copilot bot id ${found} (scan of ${owner}/${name})"
            return 0
        fi
    done
    return 1
}

ensure_bot_id() { # <owner> <name>
    [[ -n "${bot_id}" ]] && return 0
    scan_bot_id "$1" "$2" && return 0
    if [[ "${USE_BOT_ID_HINT}" == true && -n "${COPILOT_BOT_ID_HINT}" ]]; then
        bot_id="${COPILOT_BOT_ID_HINT}"
        warn "could not discover Copilot's bot id in $1/$2; falling back to the" \
            "well-known id ${bot_id}. If requests fail, pass --bot-id explicitly."
        return 0
    fi
    err "no Copilot bot id available for $1/$2; pass --bot-id"
    return 1
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
# Marker files stop a second request for the same head commit if GitHub has
# not (yet) surfaced the pending review request.
marker_path() { # <owner> <name> <pr>
    printf '%s/requested/%s__%s__%s' "${STATE_DIR}" "$1" "$2" "$3"
}

marker_matches() { # <path> <head-oid>
    [[ -s "$1" ]] && [[ "$(tr -d '[:space:]' <"$1")" == "$2" ]]
}

marker_write() { # <path> <head-oid>
    [[ "${dry_run}" == true ]] && return 0
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" >"$1"
}

# Files the review request. Returns 0 on success; on failure LAST_ERROR holds
# the raw gh output and REQUEST_ERROR a one-line summary.
REQUEST_ERROR=""
request_review() { # <pr-id> <label>
    local pr_id="$1" label="$2"
    REQUEST_ERROR=""

    if ((requests_made >= MAX_REQUESTS_PER_RUN)); then
        REQUEST_ERROR="run limit of ${MAX_REQUESTS_PER_RUN} review requests reached"
        warn "${label}: ${REQUEST_ERROR}; deferring to the next run"
        return 1
    fi
    if [[ "${dry_run}" == true ]]; then
        return 0
    fi

    if gql_mutate "${M_REQUEST_REVIEW}" -f prId="${pr_id}" -f botId="${bot_id}"; then
        requests_made=$((requests_made + 1))
        [[ "${SLEEP_BETWEEN_MUTATIONS}" != 0 ]] && sleep "${SLEEP_BETWEEN_MUTATIONS}"
        return 0
    fi
    REQUEST_ERROR="$(error_summary "$(last_error)")"
    return 1
}

react() { # <subject-id> <THUMBS_UP|THUMBS_DOWN|EYES> <label>
    if [[ "${dry_run}" == true ]]; then
        log "$3: DRY RUN would react $2"
        return 0
    fi
    if ! gql_mutate "${M_ADD_REACTION}" -f subjectId="$1" -f content="$2"; then
        # A duplicate reaction is not an error worth escalating.
        if grep -qi 'already' <<<"$(last_error)"; then
            vlog "$3: reaction $2 already present"
            return 0
        fi
        warn "$3: could not add $2 reaction: $(error_summary "$(last_error)")"
        return 1
    fi
    return 0
}

post_comment() { # <pr-id> <body> <label>
    if [[ "${dry_run}" == true ]]; then
        log "$3: DRY RUN would comment: $2"
        return 0
    fi
    if ! gql_mutate "${M_ADD_COMMENT}" -f subjectId="$1" -f body="$2"; then
        warn "$3: could not post comment: $(error_summary "$(last_error)")"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Per-PR handling
# ---------------------------------------------------------------------------
handle_pr() { # <owner> <name> <base-branch> <pr-json-file>
    local owner="$1" name="$2" base="$3" file="$4"
    local decision="" label="" mentions="" marker="" requested=false result=""

    if ! decision="$(jq -r "${jq_args[@]}" "${JQ_DECIDE}" "${file}")"; then
        err "${owner}/${name}: could not evaluate PR JSON from ${file}"
        exit_status=1
        return
    fi

    local pr_id="" number="" is_draft="" base_ref="" head_oid="" has_review="" \
        pending="" threads="" unresolved="" reviewed_head="" new_work="" \
        basis="" new_count="" new_oid="" new_date="" last_review_at="" \
        reviewed_oid=""
    IFS=$'\t' read -r pr_id number is_draft base_ref head_oid has_review pending \
        threads unresolved reviewed_head new_work basis new_count new_oid \
        new_date last_review_at reviewed_oid <<<"${decision}"

    label="${owner}/${name}#${number}"
    vlog "${label}: draft=${is_draft} base=${base_ref} head=${head_oid:0:8}" \
        "copilot_review=${has_review} pending=${pending}" \
        "copilot_threads=${threads} unresolved=${unresolved}" \
        "reviewed_head=${reviewed_head} reviewed_commit=${reviewed_oid:0:8}" \
        "last_review=${last_review_at}" \
        "new_work=${new_work} basis=${basis} new_non_merge_count=${new_count}" \
        "newest=${new_oid:0:8} authored=${new_date}"

    marker="$(marker_path "${owner}" "${name}" "${number}")"

    # --- A. mention handling, on every open PR ------------------------------
    mentions="$(jq -r "${jq_args[@]}" --arg viewer "${viewer}" --arg since "${MENTION_SINCE}" \
        "${JQ_MENTIONS}" "${file}")"
    if [[ -n "${mentions}" ]]; then
        # Decide once for the PR, then answer every unhandled mention on it.
        local want_request=true reason=""
        if [[ "${reviewed_head}" == 1 ]]; then
            want_request=false
            reason="Copilot has already reviewed the head commit (${head_oid:0:8})."
        elif [[ "${pending}" == 1 ]]; then
            want_request=false
            reason="A Copilot review is already pending on this PR."
        fi

        if [[ "${want_request}" == true ]]; then
            ensure_bot_id "${owner}" "${name}" || {
                exit_status=1
                return
            }
            if request_review "${pr_id}" "${label}"; then
                log "${label}: asked by @${MENTION_HANDLE} mention"
                log "${label}: Copilot review ${ACTION}"
                marker_write "${marker}" "${head_oid}"
                requested=true
                result=THUMBS_UP
            else
                err "${label}: failed to request Copilot review: ${REQUEST_ERROR}"
                exit_status=1
                result=THUMBS_DOWN
            fi
        else
            vlog "${label}: mention needs no action — ${reason}"
            result=EYES
        fi

        local cid="" kind="" created="" author=""
        while IFS=$'\t' read -r cid kind created author; do
            [[ -z "${cid}" ]] && continue
            vlog "${label}: answering ${kind} by @${author} (${created}) with ${result}"
            react "${cid}" "${result}" "${label}" || exit_status=1
        done <<<"${mentions}"

        if [[ "${result}" == THUMBS_DOWN ]]; then
            post_comment "${pr_id}" \
                "@${MENTION_HANDLE} could not request a Copilot review: \`${REQUEST_ERROR}\`" \
                "${label}" || true
        fi

        [[ "${requested}" == true ]] && return
    fi

    # --- B. automatic requests, gated on draft + base branch ----------------
    if [[ "${is_draft}" == 1 ]]; then
        vlog "${label}: skip — draft"
        return
    fi
    if [[ "${base_ref}" != "${base}" ]]; then
        vlog "${label}: skip — targets ${base_ref}, not ${base}"
        return
    fi
    if [[ "${pending}" == 1 ]]; then
        vlog "${label}: skip — a Copilot review request is already pending"
        return
    fi
    if [[ "${reviewed_head}" == 1 ]]; then
        vlog "${label}: skip — Copilot already reviewed head ${head_oid:0:8}"
        return
    fi
    if marker_matches "${marker}" "${head_oid}"; then
        vlog "${label}: skip — already requested for head ${head_oid:0:8}"
        return
    fi

    local why=""
    if [[ "${has_review}" == 0 ]]; then
        why="no Copilot review yet"
    elif [[ "${unresolved}" != 0 ]]; then
        vlog "${label}: skip — ${unresolved} of ${threads} Copilot thread(s) unresolved"
        return
    elif [[ "${new_work}" == 0 ]]; then
        case "${basis}" in
            rewritten)
                vlog "${label}: skip — the branch was rewritten since the review" \
                    "of ${reviewed_oid:0:8}, but nothing on it was authored" \
                    "after ${last_review_at}, so this is a restack or an amend" \
                    "rather than new work (REWRITE_TRIGGERS_REVIEW=false)"
                ;;
            *)
                vlog "${label}: skip — no non-merge commit added since the review" \
                    "of ${reviewed_oid:0:8}"
                ;;
        esac
        return
    else
        # Spell out which commit drove the decision and how it was established,
        # so a wrong call is auditable from the log alone.
        case "${basis}" in
            position)
                why="${threads} Copilot thread(s), all resolved; ${new_count}"
                why+=" non-merge commit(s) added after the reviewed commit"
                why+=" ${reviewed_oid:0:8}, newest ${new_oid:0:8}"
                ;;
            authored)
                why="${threads} Copilot thread(s), all resolved; the branch was"
                why+=" rewritten since the review, and ${new_count} non-merge"
                why+=" commit(s) on it were authored after ${last_review_at}"
                why+=" (newest ${new_oid:0:8}, authored ${new_date})"
                ;;
            rewritten)
                why="${threads} Copilot thread(s), all resolved; the branch was"
                why+=" rewritten since the review of ${reviewed_oid:0:8} with"
                why+=" nothing authored after it — a restack or an amend,"
                why+=" counted as new work because REWRITE_TRIGGERS_REVIEW=true"
                ;;
            *)
                why="${threads} Copilot thread(s), all resolved; new work detected"
                why+=" (basis=${basis})"
                ;;
        esac
    fi

    ensure_bot_id "${owner}" "${name}" || {
        exit_status=1
        return
    }
    if request_review "${pr_id}" "${label}"; then
        log "${label}: due for a Copilot review — ${why}"
        log "${label}: Copilot review ${ACTION}"
        marker_write "${marker}" "${head_oid}"
    else
        err "${label}: failed to request Copilot review: ${REQUEST_ERROR}"
        exit_status=1
    fi
}

# ---------------------------------------------------------------------------
# Per-repo handling
# ---------------------------------------------------------------------------
process_repo() { # <owner/name>
    local repo="$1" owner="" name="" base="" page="" cursor="" numbers="" n="" total=0
    owner="${repo%%/*}"
    name="${repo##*/}"
    if [[ "${repo}" != */* || "${repo}" == */*/* ]]; then
        err "invalid repo '${repo}' (expected owner/name)"
        exit_status=1
        return
    fi

    local pr_numbers=()
    if [[ -n "${only_pr}" ]]; then
        pr_numbers=("${only_pr}")
        base="${base_override:-}"
        if [[ -z "${base}" ]]; then
            if ! page="$(gql "${Q_REPO_PRS}" -f owner="${owner}" -f name="${name}")"; then
                err "${repo}: cannot read repository: $(error_summary "$(last_error)")"
                diagnose_access "${owner}" "${name}" "$(last_error)"
                exit_status=1
                return
            fi
            base="$(jq -r '.data.repository.defaultBranchRef.name // ""' <<<"${page}")"
        fi
    else
        while :; do
            if [[ -z "${cursor}" ]]; then
                page="$(gql "${Q_REPO_PRS}" -f owner="${owner}" -f name="${name}")" || {
                    err "${repo}: cannot list PRs: $(error_summary "$(last_error)")"
                    diagnose_access "${owner}" "${name}" "$(last_error)"
                    exit_status=1
                    return
                }
            else
                page="$(gql "${Q_REPO_PRS}" -f owner="${owner}" -f name="${name}" -f cursor="${cursor}")" || {
                    err "${repo}: cannot list PRs: $(error_summary "$(last_error)")"
                    exit_status=1
                    return
                }
            fi
            if [[ -z "${base}" ]]; then
                base="${base_override:-$(jq -r '.data.repository.defaultBranchRef.name // ""' <<<"${page}")}"
            fi
            numbers="$(jq -r '.data.repository.pullRequests.nodes[]?.number' <<<"${page}")"
            for n in ${numbers}; do
                pr_numbers+=("${n}")
                total=$((total + 1))
                # Stop mid-page once the cap is hit, so MAX_PRS_PER_REPO is a
                # hard limit rather than one that a single page can overshoot.
                ((total >= MAX_PRS_PER_REPO)) && break
            done
            if [[ "$(jq -r '.data.repository.pullRequests.pageInfo.hasNextPage' <<<"${page}")" == true &&
            ${total} -lt ${MAX_PRS_PER_REPO} ]]; then
                cursor="$(jq -r '.data.repository.pullRequests.pageInfo.endCursor' <<<"${page}")"
            else
                break
            fi
        done
    fi

    [[ -z "${base}" ]] && {
        err "${repo}: could not determine the base branch"
        exit_status=1
        return
    }

    local total_prs=${#pr_numbers[@]} started=${SECONDS}
    log "${repo}: base branch ${base}, ${total_prs} open PR(s) to inspect" \
        "(one API call each, so expect roughly $(((total_prs + 30) / 60 + 1)) minute(s))"

    # Each PR is decided as soon as it is fetched, so output starts immediately
    # rather than after the last fetch. The one thing that has to happen before
    # any decision is knowing Copilot's bot node id: it is scavenged from
    # whichever PR first exposes a Copilot review or pending request. Until that
    # turns up, PRs are queued; once it does, the queue is flushed and
    # everything after it streams. With the id already cached — the common case
    # — nothing is ever queued.
    local dir="${TMPDIR_RUN}/${owner}-${name}" out="" file="" idx=0
    mkdir -p "${dir}"
    local queued=()

    for n in "${pr_numbers[@]}"; do
        idx=$((idx + 1))
        vlog "${repo}#${n}: fetching (${idx}/${total_prs})"

        file="${dir}/pr-${n}.json"
        if ! out="$(gql "${Q_PR}" -f owner="${owner}" -f name="${name}" -F number="${n}")"; then
            err "${repo}#${n}: cannot read PR: $(error_summary "$(last_error)")"
            exit_status=1
            continue
        fi
        if ! jq -e '.data.repository.pullRequest != null' >/dev/null 2>&1 <<<"${out}"; then
            err "${repo}#${n}: no such PR"
            exit_status=1
            continue
        fi
        jq '.data.repository.pullRequest' <<<"${out}" >"${file}"
        harvest_bot_id "${file}"

        if [[ -n "${bot_id}" ]]; then
            if ((${#queued[@]} > 0)); then
                vlog "${repo}: bot id known now, catching up on ${#queued[@]} queued PR(s)"
                local qf=""
                for qf in "${queued[@]}"; do
                    handle_pr "${owner}" "${name}" "${base}" "${qf}"
                done
                queued=()
            fi
            handle_pr "${owner}" "${name}" "${base}" "${file}"
        else
            queued+=("${file}")
        fi

        # A heartbeat for non-verbose runs, which are otherwise silent for every
        # PR that needs no action.
        if [[ "${verbose}" != true ]] && ((PROGRESS_EVERY > 0)) &&
            ((idx % PROGRESS_EVERY == 0)) && ((idx < total_prs)); then
            log "${repo}: ${idx}/${total_prs} inspected, $((SECONDS - started))s elapsed"
        fi
    done

    if ((${#queued[@]} > 0)); then
        # No PR in the repo exposed the bot id; handle_pr falls back to the
        # discovery scan, or the well-known id, when it needs to act.
        local qf=""
        for qf in "${queued[@]}"; do
            handle_pr "${owner}" "${name}" "${base}" "${qf}"
        done
    fi

    log "${repo}: ${idx}/${total_prs} inspected in $((SECONDS - started))s"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
# Everything the script needs is checked up front, because a missing
# dependency discovered mid-run is far more confusing than one reported at the
# start. `flock` in particular used to fail open: "command not found" is exit
# 127, which is indistinguishable from "the lock is held" unless you look, so a
# missing flock silently turned every run into a no-op.

# Package suggestions, tailored to whatever this machine looks like.
install_hint() { # <binary>
    local os
    os="$(uname -s 2>/dev/null || echo unknown)"
    case "$1:${os}" in
        gh:Darwin) echo "brew install gh" ;;
        gh:*) echo "see https://github.com/cli/cli#installation" ;;
        jq:Darwin) echo "brew install jq" ;;
        jq:*) echo "apt-get install jq  (or dnf install jq)" ;;
        flock:Darwin) echo "brew install flock" ;;
        flock:*) echo "apt-get install util-linux  (or dnf install util-linux)" ;;
        bash:Darwin) echo "brew install bash, then run the script with that bash" ;;
        bash:*) echo "apt-get install bash" ;;
        *) echo "install $1 and make sure it is on PATH" ;;
    esac
}

check_bash_version() {
    # 4.4 is the floor: earlier releases treat "${empty_array[@]}" as an unbound
    # variable under `set -u`, which this script relies on throughout. macOS
    # still ships 3.2 as /bin/bash, so this fires there unless a newer bash is
    # first on PATH.
    if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
        err "bash 4.4 or newer is required; this is ${BASH_VERSION:-unknown}" \
            "(${BASH}). Fix: $(install_hint bash)"
        exit 2
    fi
}

require_binaries() { # <binary>...
    local b missing=()
    for b in "$@"; do
        command -v "${b}" >/dev/null 2>&1 || missing+=("${b}")
    done
    if ((${#missing[@]} > 0)); then
        err "missing required program(s): ${missing[*]}"
        for b in "${missing[@]}"; do
            err "  ${b} — $(install_hint "${b}")"
        done
        exit 2
    fi
}

# GNU and BSD date disagree about relative dates, and this runs on Linux VMs
# but gets tested on macOS. Probe once, then go through date_days_ago().
DATE_FLAVOUR=""
detect_date_flavour() {
    if date -u -d "1 day ago" +%Y >/dev/null 2>&1; then
        DATE_FLAVOUR=gnu
    elif date -u -v-1d +%Y >/dev/null 2>&1; then
        DATE_FLAVOUR=bsd
    else
        err "cannot compute relative dates with this 'date' implementation" \
            "(neither 'date -d' nor 'date -v' works)"
        exit 2
    fi
}

date_days_ago() { # <days>
    case "${DATE_FLAVOUR}" in
        gnu) date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ ;;
        bsd) date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ ;;
        *)
            err "date_days_ago called before detect_date_flavour"
            exit 2
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Debug shortcut: evaluate a saved pullRequest object and print the outcome.
if [[ -n "${explain_file}" ]]; then
    check_bash_version
    require_binaries jq
    viewer="${VIEWER_LOGIN:-xrplf-bot}"
    MENTION_SINCE="${MENTION_SINCE:-1970-01-01T00:00:00Z}"
    printf 'id\tnumber\tdraft\tbase\thead\thas_review\tpending\tthreads\tunresolved\treviewed_head\tnew_work\tbasis\tnew_count\tnew_oid\tnew_date\tlast_review\treviewed_oid\n'
    jq -r "${jq_args[@]}" "${JQ_DECIDE}" "${explain_file}"
    printf -- '--- mentions (id, kind, createdAt, author) ---\n'
    jq -r "${jq_args[@]}" --arg viewer "${viewer}" --arg since "${MENTION_SINCE}" \
        "${JQ_MENTIONS}" "${explain_file}"
    exit 0
fi

check_bash_version
require_binaries gh jq flock mktemp find sed grep tr cut
detect_date_flavour

# Repos: CLI arguments, else $REPOS.
if [[ ${#repos[@]} -eq 0 && -n "${REPOS:-}" ]]; then
    read -r -a repos <<<"${REPOS}"
fi
[[ ${#repos[@]} -eq 0 ]] && usage 2

if [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]] && ! gh auth status >/dev/null 2>&1; then
    die "no GitHub credentials: set GH_TOKEN/GITHUB_TOKEN or run 'gh auth login'"
fi

[[ "${dry_run}" == true ]] && ACTION="would be requested, but this is a dry run"

mkdir -p "${STATE_DIR}"

# One instance at a time. A run that overlaps its predecessor would re-decide
# on stale state and could double-request. flock is verified present above, but
# the status is still inspected rather than lumped in with contention: 127 or
# 126 means the lock was never taken, and carrying on unlocked is safer than
# pretending a peer holds it.
exec 9>"${LOCK_FILE}"
lock_status=0
flock -n 9 || lock_status=$?
case "${lock_status}" in
    0) ;;
    126 | 127)
        err "flock could not be executed (exit ${lock_status}); refusing to run" \
            "unlocked. Fix: $(install_hint flock)"
        exit 2
        ;;
    *)
        log "another instance is running (flock exit ${lock_status}); exiting"
        exit 0
        ;;
esac

TMPDIR_RUN="$(mktemp -d)"
ERR_FILE="${TMPDIR_RUN}/last-error"
# Invoked indirectly via the trap below, not called directly.
# shellcheck disable=SC2329
cleanup() { rm -rf "${TMPDIR_RUN}"; }
trap cleanup EXIT

MENTION_SINCE="$(date_days_ago "${MENTION_MAX_AGE_DAYS}")"

viewer="$(gh api graphql -f query='{ viewer { login } }' --jq .data.viewer.login 2>/dev/null || true)"
[[ -z "${viewer}" ]] && die "cannot identify the authenticated account (check the token)"

log "copilot-review-bot ${VERSION} starting as @${viewer} (dry_run=${dry_run}," \
    "handle=@${MENTION_HANDLE}, mentions since ${MENTION_SINCE})"

load_cached_bot_id

for repo in "${repos[@]}"; do
    process_repo "${repo}"
done

# Marker files for long-since-merged PRs are harmless but do accumulate.
find "${STATE_DIR}/requested" -type f -mtime +90 -delete 2>/dev/null || true

log "done: ${requests_made} review request(s) filed, exit ${exit_status}"
exit "${exit_status}"

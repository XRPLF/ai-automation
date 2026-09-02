#!/usr/bin/env bash
#
# copilot-review-bot-e2e-test.sh - drive copilot-review-bot.sh end to end with
# a stub `gh` on PATH, and assert on what it did: which mutations it sent, what
# it logged, and what it exited with.
#
# copilot-review-bot-test.sh covers the decision rules. This covers everything
# around them, which is where the interesting failures live: the per-run cap,
# the transient/permanent split, the reactions that follow from it, the state
# that has to survive a run, and the shape of the log.
#
# No network and no GitHub token. Local state only; the gs:// backend has its own
# suite, copilot-review-bot-gcs-test.sh, which stubs the Cloud Storage API.
#
# Usage: ./copilot-review-bot-e2e-test.sh [path-to-copilot-review-bot.sh]
#
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test-lib.sh
. "${SUITE_DIR}/test-lib.sh"

BOT="$(resolve_bot "${SUITE_DIR}/.." "${1:-}")"
require_tools jq flock
BASH_BIN="${BASH}"
TOOL_PATH="$(build_tool_path flock)"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
current=""

# ---------------------------------------------------------------------------
# The stub gh. Dispatches on the GraphQL document it is handed, serves fixtures
# out of ${FAKE_DIR}, and appends one line per call to calls.log so the test can
# assert on the mutations that were actually sent.
# ---------------------------------------------------------------------------
make_stub_gh() { # <dir>
    local bin="$1/bin"
    mkdir -p "${bin}"
    cat >"${bin}/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
D="${FAKE_DIR}"
log="${D}/calls.log"

[[ "${1:-}" == auth ]] && exit 0

query=""; number=""; cursor=""; content=""; subject=""; body=""; pr_id=""
login=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f | -F)
            case "${2%%=*}" in
                query) query="${2#*=}" ;;
                number) number="${2#*=}" ;;
                cursor) cursor="${2#*=}" ;;
                content) content="${2#*=}" ;;
                subjectId) subject="${2#*=}" ;;
                body) body="${2#*=}" ;;
                prId) pr_id="${2#*=}" ;;
                pullRequestId) pr_id="${2#*=}" ;;
                login) login="${2#*=}" ;;
            esac
            shift 2
            ;;
        *) shift ;;
    esac
done

case "${query}" in
    *requestReviewsByLogin*)
        # Which of the three lists the reviewer travelled in is read back out of the
        # document, not assumed, because the field name is the half of the request
        # the bot picks itself. The PR is on the wire as a node id only, so the
        # number comes back off the id this stub's fixtures build: PR_<number>.
        field=unknown
        case "${query}" in
            *'botLogins: [$login]'*) field=botLogins ;;
            *'userLogins: [$login]'*) field=userLogins ;;
            *'teamSlugs: [$login]'*) field=teamSlugs ;;
        esac
        printf 'request\t%s\t%s\t%s\n' "${pr_id#PR_}" "${login}" "${field}" >>"${log}"
        if [[ -f "${D}/fail-request" ]]; then
            cat "${D}/fail-request" >&2
            exit 1
        fi
        printf '{"data":{"requestReviewsByLogin":{"clientMutationId":null}}}\n'
        ;;
    *"viewer { login }"*)
        # The identity call is the first thing the bot makes, so both ways it can go
        # wrong have to be reachable: a hard failure and an answer naming nobody.
        if [[ -f "${D}/fail-viewer" ]]; then
            cat "${D}/fail-viewer" >&2
            exit 1
        fi
        [[ -f "${D}/empty-viewer" ]] && exit 0
        printf 'xrplf-bot\n'
        ;;
    *addReaction*)
        printf 'react\t%s\t%s\n' "${subject}" "${content}" >>"${log}"
        if [[ -f "${D}/fail-react" ]]; then
            cat "${D}/fail-react" >&2
            exit 1
        fi
        printf '{"data":{"addReaction":{"reaction":{"content":"%s"}}}}\n' "${content}"
        ;;
    *addComment*)
        printf 'comment\t%s\t%s\n' "${subject}" "${body}" >>"${log}"
        if [[ -f "${D}/fail-comment" ]]; then
            cat "${D}/fail-comment" >&2
            exit 1
        fi
        printf '{"data":{"addComment":{"clientMutationId":null}}}\n'
        ;;
    *"pullRequests(states: OPEN"*)
        printf 'list\t%s\n' "${cursor:-first}" >>"${log}"
        # Per-page faults, keyed on the cursor, so a first page can succeed and a
        # later one fail. Pagination bugs only show up across two calls.
        if [[ -f "${D}/fail-page-${cursor:-first}" ]]; then
            cat "${D}/fail-page-${cursor:-first}" >&2
            exit 1
        fi
        cat "${D}/page-${cursor:-first}.json"
        ;;
    *reviewThreads*)
        printf 'pr\t%s\n' "${number}" >>"${log}"
        if [[ -f "${D}/fail-pr" ]]; then
            cat "${D}/fail-pr" >&2
            exit 1
        fi
        [[ -f "${D}/null-pr" ]] && {
            printf '{"data":{"repository":{"pullRequest":null}}}\n'
            exit 0
        }
        src="${D}/pr-${number}.json"
        [[ -f "${src}" ]] || src="${D}/pr-any.json"
        if [[ -f "${src}" ]]; then
            jq -c --argjson n "${number}" \
                '{data:{repository:{pullRequest:(. + {id:("PR_"+($n|tostring)), number:$n})}}}' "${src}"
        else
            printf '{"data":{"repository":{"pullRequest":null}}}\n'
        fi
        ;;
    *)
        printf 'stub gh: unexpected query\n' >&2
        exit 1
        ;;
esac
exit 0
STUB
    chmod +x "${bin}/gh"
}

# ---------------------------------------------------------------------------
# Scenario helpers
# ---------------------------------------------------------------------------
# The bot namespaces its state by the repository it watches, so the lock and the
# markers for the one repo every scenario here runs against live this far below
# ${STATE_DIR}. Named once, so a case that plants or inspects a state file says which
# file rather than restating the layout.
STATE_SUB="XRPLF/rippled"

# scenario <name> -> creates ${ROOT}/<name>, echoes the path, sets ${current}
scenario() {
    current="${ROOT}/$1"
    # Created up front, so a case can plant a lock or a marker file before the run
    # without repeating the mkdir. The bot creates it itself when it is missing.
    mkdir -p "${current}/state/${STATE_SUB}"
    make_stub_gh "${current}"
    printf '%s' "${current}"
}

# One PR list page. numbers are given as a whitespace separated list.
page() { # <dir> <cursor-name> <next-cursor-or-empty> <numbers...>
    local d="$1" name="$2" next="$3"
    shift 3
    local has=false
    [[ -n "${next}" ]] && has=true
    jq -n --argjson nums "$(printf '%s\n' "$@" | jq -R -s 'split("\n")|map(select(length>0)|tonumber)')" \
        --argjson has "${has}" --arg next "${next}" '
        {data:{repository:{
            defaultBranchRef:{name:"develop"},
            pullRequests:{
                pageInfo:{hasNextPage:$has, endCursor:$next},
                nodes:($nums|map({number:.}))}}}}' >"${d}/page-${name}.json"
}

# A PR nobody has reviewed, so it is due for one.
pr_fresh() { # <dir> <file-name> [extra-json]
    local d="$1" f="$2" extra="${3:-{\}}"
    jq -n --argjson extra "${extra}" '{
        isDraft:false, baseRefName:"develop", headRefOid:"head1",
        author:{login:"alice"},
        commits:{nodes:[{commit:{oid:"head1",
            authoredDate:"2026-08-01T10:00:00Z",
            committedDate:"2026-08-01T10:00:00Z",
            parents:{totalCount:1}}}]}
    } + $extra' >"${d}/${f}"
}

# The @mention that a PR carries when somebody asks for a review by hand.
MENTION='{"comments":{"nodes":[{"id":"IC_1","createdAt":"2026-08-20T10:00:00Z",
         "body":"@xrplf-bot please review","author":{"login":"alice"},
         "reactionGroups":[]}]}}'

# Settings every launch needs, whether it goes through run() or not. Held in one array
# so a new inline launch cannot omit one, which is how six of them had already lost
# GITHUB_API_ROOT.
#
# GITHUB_API_ROOT is the load-bearing one: it points diagnose_access's anonymous probe
# at a dead port, and it is the only thing standing between a read-failure case and a
# real request to api.github.com from CI.
#
# because every assertion here is on the retry having happened,
# and none is on how long it waited. At the production default of 3 a single failed read
# sleeps 9 seconds to prove nothing. It sits before RUN_ENV in every launch, so a
# scenario that needs a different value can still set one.
BASE_ENV=(
    GITHUB_API_ROOT=http://127.0.0.1:1
    MENTION_MAX_AGE_DAYS=3650
    GH_RETRY_BASE_SECONDS=0
)

# Extra VAR=VALUE entries for the next run(), reset after it. The environment is
# wiped with env -i, so anything the bot must see has to go through here.
RUN_ENV=()

# A fatal that ends in `usage 2` prints the help text after its event, so that log is
# not all JSON. events() reads the whole file in one jq -s and reports a parse error
# for any of it, so those cases assert against a JSON-only copy.
json_only() { # <out-log> -> path to a copy holding only the events
    grep '^{' "$1" >"$1.json" || true
    printf '%s' "$1.json"
}

# run <dir> [args...] -> exit code in ${rc}, stdout in <dir>/out.log
run() {
    local d="$1"
    shift
    : >"${d}/calls.log"
    rc=0
    # RUN_ENV comes last so it can override a default, which is the whole point
    # of it: GH_TOKEN in particular has to be replaceable to reach the
    # token-shape diagnostics.
    env -i \
        PATH="${d}/bin:${TOOL_PATH}:/usr/bin:/bin" \
        HOME="${d}" \
        FAKE_DIR="${d}" \
        GH_TOKEN=stub-token \
        STATE_DIR="${d}/state" \
        SLEEP_BETWEEN_MUTATIONS=0 \
        LOG_FORMAT=json \
        "${BASE_ENV[@]}" \
        ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
        "${BASH_BIN}" "${BOT}" --repo XRPLF/rippled "$@" >"${d}/out.log" 2>&1 || rc=$?
    LAST_LOG="${d}/out.log"
    RUN_ENV=()
}

# ===========================================================================
printf '\n== the per-run cap stops the run instead of failing it ==\n'
# Three PRs are due, the cap is one. Exactly one request goes out, the rest are
# left for the next run, and none of that is an error.
d="$(scenario cap)"
page "${d}" first "" 101 102 103
pr_fresh "${d}" pr-any.json
run "${d}" --max-requests 1
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "one review request was filed" 1 "$(calls "${d}/calls.log" request)"
assert_eq "the run stopped early, once" 1 "$(events "${d}/out.log" '.event=="repo.stopped"')"
assert_eq "stopping early is a WARNING" 1 "$(events "${d}/out.log" '.event=="repo.stopped" and .severity=="WARNING"')"
assert_eq "no ERROR was logged" 0 "$(events "${d}/out.log" '.severity=="ERROR"')"
# The budget is spent by the first PR, so the other two are never fetched at
# all, since the only thing left to do with them is defer them at one call each.
assert_eq "the remaining PRs were never fetched" 1 "$(calls "${d}/calls.log" pr)"
assert_eq "the two unread PRs are accounted for" 1 \
    "$(events "${d}/out.log" '.event=="repo.stopped" and .remaining==2 and .inspected==1')"
# The three keys every repo.stopped shares, whatever stopped it. Asserted as an
# invariant rather than per case, so a new stop reason cannot quietly omit one.
assert_eq "every repo.stopped carries the shared keys" 0 \
    "$(events "${d}/out.log" '.event=="repo.stopped" and ((.inspected|type)!="number" or (.total|type)!="number" or (.remaining|type)!="number")')"
assert_log_shape "${d}/out.log" "cap"

printf '\n== a repository past its expected PR count says so, once ==\n'
# The declared figure lives in jobs.json, which the bot never reads, and the true count is
# not known until the list is paged, so this run is the only place both numbers exist. It is
# what turns a year of quiet drift into something the ERROR/WARNING alerting catches.
d="$(scenario expected_prs)"
page "${d}" first "" 101 102 103
pr_fresh "${d}" pr-any.json
RUN_ENV=(EXPECTED_OPEN_PRS=2)
run "${d}" --dry-run
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "it warns exactly once" 1 \
    "$(events "${d}/out.log" '.event=="repo.more_prs_than_expected"')"
assert_eq "at WARNING, not ERROR" 1 \
    "$(events "${d}/out.log" '.event=="repo.more_prs_than_expected" and .severity=="WARNING"')"
assert_eq "carrying both numbers and the gap" 1 \
    "$(events "${d}/out.log" '.event=="repo.more_prs_than_expected" and .open_prs==3 and .expected_open_prs==2 and .over_by==1')"
assert_eq "and a remedy" 1 \
    "$(events "${d}/out.log" '.event=="repo.more_prs_than_expected" and .remedy=="raise_expected_open_prs"')"
assert_eq "no ERROR was logged" 0 "$(events "${d}/out.log" '.severity=="ERROR"')"
assert_log_shape "${d}/out.log" "expected_prs"

printf '\n== at or under the expected count it stays quiet ==\n'
# Only under-declaring costs anything, so an over-declaration must not warn. Exactly equal
# is not over.
for expected in 3 4 99; do
    d="$(scenario "expected_ok_${expected}")"
    page "${d}" first "" 101 102 103
    pr_fresh "${d}" pr-any.json
    RUN_ENV=(EXPECTED_OPEN_PRS="${expected}")
    run "${d}" --dry-run
    assert_eq "EXPECTED_OPEN_PRS=${expected} over 3 PRs does not warn" 0 \
        "$(events "${d}/out.log" '.event=="repo.more_prs_than_expected"')"
done

printf '\n== unset, the check is switched off entirely ==\n'
# Empty is how a local run and every pre-existing job get it. 0 cannot be the off switch,
# because 0 is a real expectation meaning "warn about any open PR at all".
d="$(scenario expected_unset)"
page "${d}" first "" 101 102 103
pr_fresh "${d}" pr-any.json
run "${d}" --dry-run
assert_eq "no warning without the variable" 0 \
    "$(events "${d}/out.log" '.event=="repo.more_prs_than_expected"')"

d="$(scenario expected_zero)"
page "${d}" first "" 101
pr_fresh "${d}" pr-any.json
RUN_ENV=(EXPECTED_OPEN_PRS=0)
run "${d}" --dry-run
assert_eq "but 0 is an expectation, not off" 1 \
    "$(events "${d}/out.log" '.event=="repo.more_prs_than_expected" and .expected_open_prs==0')"

printf '\n== a non-numeric expectation is refused at startup ==\n'
# It reaches the log as a raw JSON number, so an unchecked value would emit a line no JSON
# parser accepts - losing the very event that reports the failure.
d="$(scenario expected_bad)"
page "${d}" first "" 101
pr_fresh "${d}" pr-any.json
RUN_ENV=(EXPECTED_OPEN_PRS=lots)
run "${d}"
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "and it names the setting" 1 \
    "$(events "$(json_only "${d}/out.log")" '.event=="run.fatal" and .reason=="bad_option" and .setting=="EXPECTED_OPEN_PRS"')"

printf '\n== a dry run walks past the cap but says what the next run would file ==\n'
# The cap bounds mutations and a dry run has none, so it keeps going and reports the
# whole backlog. That total is not a prediction, though: a real run would stop at the
# cap. Both numbers are therefore on run.done, or would_file reads as "this is about to
# happen" when it is really "this is how far behind we are".
d="$(scenario dry_cap)"
page "${d}" first "" 101 102 103
pr_fresh "${d}" pr-any.json
run "${d}" --dry-run --max-requests 1
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "nothing was requested" 0 "$(calls "${d}/calls.log" request)"
# The whole point: a real run fetches one PR here and stops. This one fetches all three.
assert_eq "every PR was still fetched" 3 "$(calls "${d}/calls.log" pr)"
assert_eq "the run did not stop early" 1 \
    "$(events "${d}/out.log" '.event=="run.done" and .stopped_early==false and .stop_reason=="none"')"
assert_eq "would_file is the whole backlog" 1 \
    "$(events "${d}/out.log" '.event=="run.done" and .would_file==3')"
assert_eq "would_file_next_run is bounded by the cap" 1 \
    "$(events "${d}/out.log" '.event=="run.done" and .would_file_next_run==1')"
assert_eq "and the message says both" 1 \
    "$(events "${d}/out.log" '.event=="run.done" and (.message|test("3 review request\\(s\\) would be filed, 1 of them on the next run"))')"
assert_eq "no ERROR was logged" 0 "$(events "${d}/out.log" '.severity=="ERROR"')"
assert_log_shape "${d}/out.log" "dry_cap"

printf '\n== under the cap, a dry run does not repeat itself ==\n'
# would_file_next_run still has to be a number on every run.done, so a metric on it
# cannot hit a missing field, but the message must not read "3 would be filed, 3 of them
# on the next run".
d="$(scenario dry_under_cap)"
page "${d}" first "" 101 102 103
pr_fresh "${d}" pr-any.json
run "${d}" --dry-run --max-requests 25
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "both numbers are the backlog" 1 \
    "$(events "${d}/out.log" '.event=="run.done" and .would_file==3 and .would_file_next_run==3')"
assert_eq "the message states it once" 0 \
    "$(events "${d}/out.log" '.event=="run.done" and (.message|test("of them on the next run"))')"

printf '\n== a real run reports the field as a number too ==\n'
# Typed on every run.done, not only on a dry run, because Cloud Logging builds metrics
# on it and a field that is sometimes absent cannot carry one.
d="$(scenario live_next_run_field)"
page "${d}" first "" 101
pr_fresh "${d}" pr-any.json
run "${d}"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "would_file_next_run is 0 on a live run" 1 \
    "$(events "${d}/out.log" '.event=="run.done" and (.would_file_next_run|type)=="number" and .would_file_next_run==0')"

printf '\n== a deferred mention is left unanswered, not thumbed down ==\n'
# The cap is zero, so the mention cannot be served this run. Reacting would mark
# it answered forever, so nothing is touched.
d="$(scenario cap_mention)"
page "${d}" first "" 201
pr_fresh "${d}" pr-201.json "${MENTION}"
run "${d}" --max-requests 0
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "no review request was attempted" 0 "$(calls "${d}/calls.log" request)"
assert_eq "no reaction was added" 0 "$(calls "${d}/calls.log" react)"
assert_eq "no comment was posted" 0 "$(calls "${d}/calls.log" comment)"
assert_eq "the cap is announced exactly once" 1 "$(events "${d}/out.log" '.event=="review.deferred" and .severity=="WARNING"')"
assert_eq "no ERROR was logged" 0 "$(events "${d}/out.log" '.severity=="ERROR"')"

printf '\n== a transient failure is retried later, not recorded on the PR ==\n'
d="$(scenario transient)"
page "${d}" first "" 301
pr_fresh "${d}" pr-301.json "${MENTION}"
printf 'gh: HTTP 502 Bad Gateway (https://api.github.com/graphql)\n' >"${d}/fail-request"
run "${d}"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the request was attempted once" 1 "$(calls "${d}/calls.log" request)"
assert_eq "the mention is left unreacted" 0 "$(calls "${d}/calls.log" react)"
assert_eq "no error comment was posted" 0 "$(calls "${d}/calls.log" comment)"
assert_eq "logged as a WARNING" 1 "$(events "${d}/out.log" '.event=="review.request_failed" and .severity=="WARNING" and .failure_class=="transient"')"
assert_eq "no ERROR was logged" 0 "$(events "${d}/out.log" '.severity=="ERROR"')"
assert_eq "counted as a transient failure to retry" 1 "$(events "${d}/out.log" '.event=="run.done" and .transient_failures==1')"

printf '\n== a secondary rate limit is a 403 but still transient ==\n'
# The trap this exists for: GitHub reports its secondary rate limit with a 403,
# and a status-code-only rule would call that permanent and thumb the mention
# down, burning somebody's request over a wait.
d="$(scenario secondary_limit)"
page "${d}" first "" 401
pr_fresh "${d}" pr-401.json "${MENTION}"
printf 'gh: HTTP 403: You have exceeded a secondary rate limit. Please wait a few minutes before you try again.\n' \
    >"${d}/fail-request"
run "${d}"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the mention is left unreacted" 0 "$(calls "${d}/calls.log" react)"
assert_eq "classified transient" 1 "$(events "${d}/out.log" '.event=="review.request_failed" and .failure_class=="transient"')"

printf '\n== a permanent failure is reported on the PR and fails the run ==\n'
d="$(scenario permanent)"
page "${d}" first "" 501
pr_fresh "${d}" pr-501.json "${MENTION}"
printf 'gh: HTTP 403: Resource not accessible by personal access token\n' >"${d}/fail-request"
run "${d}"
assert_eq "exit status is 1" 1 "${rc}"
assert_eq "the mention got a thumbs down" 1 "$(grep -c 'THUMBS_DOWN' "${d}/calls.log")"
assert_eq "the error was posted as a comment" 1 "$(calls "${d}/calls.log" comment)"
assert_eq "logged as an ERROR" 1 "$(events "${d}/out.log" '.event=="review.request_failed" and .severity=="ERROR" and .failure_class=="permanent"')"
assert_eq "the request was attempted once, not twice" 1 "$(calls "${d}/calls.log" request)"
assert_eq "the failure was logged once, not twice" 1 "$(events "${d}/out.log" '.event=="review.request_failed"')"

printf '\n== the reviewer is asked for by login, with no node id anywhere ==\n'
# GitHub's node id for Copilot is GitHub's to change, and the id-based requestReviews
# mutation accepts a stale one, so the request would land on nothing and the PR would
# sit there looking reviewed-pending forever. requestReviewsByLogin takes the login,
# so nothing here has an id to go stale.
d="$(scenario reviewer_by_name)"
page "${d}" first "" 601
pr_fresh "${d}" pr-601.json
run "${d}"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the request went to Copilot's login, in botLogins" 1 \
    "$(grep -cF "$(printf 'request\t601\tcopilot-pull-request-reviewer[bot]\tbotLogins')" \
        "${d}/calls.log")"
assert_eq "no run.start line carries a bot id" 0 \
    "$(events "${d}/out.log" '.bot_id != null')"
assert_eq "run.start names the reviewer that was sent" 1 \
    "$(events "${d}/out.log" '.event=="run.start" and .reviewer=="copilot-pull-request-reviewer[bot]"')"
assert_eq "and the list it was sent in" 1 \
    "$(events "${d}/out.log" '.event=="run.start" and .reviewer_field=="botLogins"')"

printf '\n== each kind of reviewer goes in its own list, verbatim ==\n'
# requestReviewsByLogin has three lists and the value alone says which one it belongs
# in, so this is the case that fails if that rule ever drifts: a bot in userLogins, or
# a team slug split into an owner and a name, is a permanent failure on every due PR.
# The login itself is never rewritten, so the setting, the log and the wire agree.
while read -r who field; do
    d="$(scenario "reviewer_$(printf '%s' "${who}" | tr -cd '[:alnum:]')")"
    page "${d}" first "" 701
    pr_fresh "${d}" pr-701.json
    run "${d}" --reviewer "${who}"
    assert_eq "${who}: exit status is 0" 0 "${rc}"
    assert_eq "${who}: sent verbatim, in ${field}" 1 \
        "$(grep -cF "$(printf 'request\t701\t%s\t%s' "${who}" "${field}")" "${d}/calls.log")"
    assert_eq "${who}: and logged verbatim" 1 \
        "$(events "${d}/out.log" '.event=="run.start" and .reviewer=="'"${who}"'" and .reviewer_field=="'"${field}"'"')"
done <<'REVIEWERS'
monalisa userLogins
XRPLF/reviewers teamSlugs
copilot-pull-request-reviewer[bot] botLogins
REVIEWERS

printf '\n== gh'"'"'s @ alias is refused, not rewritten ==\n'
# '@copilot' was the default while gh made this call, and it is not a login: the
# mutation would put it in userLogins and GitHub would refuse it once per due PR. It is
# refused here instead, before any PR is read, with the right spelling in the message.
d="$(scenario reviewer_at_alias)"
page "${d}" first "" 703
pr_fresh "${d}" pr-703.json
run "${d}" --reviewer '@copilot'
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "it says why, and names what was given" 1 \
    "$(events "${d}/out.log" '.event=="run.fatal" and .reason=="invalid_reviewer" and .given=="@copilot"')"
assert_eq "the message names the login to use instead" 1 \
    "$(events "${d}/out.log" '.event=="run.fatal" and (.message | test("copilot-pull-request-reviewer\\[bot\\]"))')"
assert_eq "no PR was read and no request was filed" 0 \
    "$(calls "${d}/calls.log" request)"

printf '\n== an empty reviewer is refused once, not per PR ==\n'
d="$(scenario reviewer_empty)"
page "${d}" first "" 702
pr_fresh "${d}" pr-702.json
run "${d}" --reviewer ''
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "it says why" 1 \
    "$(events "${d}/out.log" '.event=="run.fatal" and .reason=="invalid_reviewer"')"
assert_eq "no PR was even read" 0 "$(calls "${d}/calls.log" pr)"

printf '\n== state survives the run, so a request is not filed twice ==\n'
d="$(scenario state)"
page "${d}" first "" 801
pr_fresh "${d}" pr-801.json
run "${d}"
assert_eq "first run files the request" 1 "$(calls "${d}/calls.log" request)"
assert_eq "the marker was stored" "head1" \
    "$(jq -r '."XRPLF/rippled#801".head // "missing"' "${d}/state/${STATE_SUB}/requested.json" 2>/dev/null)"
run "${d}" -v
assert_eq "second run files nothing" 0 "$(calls "${d}/calls.log" request)"
assert_eq "and says why" 1 "$(events "${d}/out.log" '.event=="pr.skipped" and .reason=="already_requested"')"

printf '\n== every open PR is inspected, however many there are ==\n'
# No ceiling: a cap here would leave the tail of a busy repo permanently unseen.
d="$(scenario no_pr_cap)"
mapfile -t batch1 < <(seq 1 100)
mapfile -t batch2 < <(seq 101 200)
mapfile -t batch3 < <(seq 201 320)
page "${d}" first C1 "${batch1[@]}"
page "${d}" C1 C2 "${batch2[@]}"
page "${d}" C2 "" "${batch3[@]}"
# Drafts, so all 320 are inspected and none is acted on.
jq -n '{isDraft:true, baseRefName:"develop", headRefOid:"head1",
        commits:{nodes:[{commit:{oid:"head1",authoredDate:"2026-08-01T10:00:00Z",
        committedDate:"2026-08-01T10:00:00Z",parents:{totalCount:1}}}]}}' >"${d}/pr-any.json"
run "${d}"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "all three list pages were read" 3 "$(calls "${d}/calls.log" list)"
assert_eq "all 320 PRs were inspected" 320 "$(calls "${d}/calls.log" pr)"
assert_eq "the repo reported 320 open PRs" 1 "$(events "${d}/out.log" '.event=="repo.start" and .open_prs==320')"

printf '\n== a bad option is refused before any work starts ==\n'
d="$(scenario bad_option)"
page "${d}" first "" 901
pr_fresh "${d}" pr-901.json
run "${d}" --max-requests not-a-number
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "nothing was queried" 0 "$(calls "${d}/calls.log" pr)"
assert_eq "the bad setting is named" 1 \
    "$(events "${d}/out.log" '.event=="run.fatal" and .setting=="MAX_REQUESTS_PER_RUN"')"

printf '\n== a second run exits quietly while the first holds the lock ==\n'
d="$(scenario lock)"
page "${d}" first "" 1001
pr_fresh "${d}" pr-1001.json
mkdir -p "${d}/state"
exec 8>"${d}/state/${STATE_SUB}/lock"
flock -n 8
run "${d}"
exec 8>&-
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "nothing was queried" 0 "$(calls "${d}/calls.log" pr)"
assert_eq "and it said so" 1 "$(events "${d}/out.log" '.event=="run.skipped" and .reason=="locked"')"

printf '\n== a dry run proceeds even while another instance holds the lock ==\n'
# A dry run takes no lock of its own, so it has none to contend with. It reads
# GitHub concurrently with whatever the lock holder is doing, which is fine: a
# dry run makes no mutation for either run to race against.
d="$(scenario dry_run_ignores_lock)"
page "${d}" first "" 1002
pr_fresh "${d}" pr-1002.json
mkdir -p "${d}/state"
exec 8>"${d}/state/${STATE_SUB}/lock"
flock -n 8
run "${d}" --dry-run
exec 8>&-
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "it was not skipped" 0 "$(events "${d}/out.log" '.event=="run.skipped"')"
assert_eq "the PR was still evaluated" 1 "$(calls "${d}/calls.log" pr)"

printf '\n== a local STATE_DIR on Cloud Run says so, every run ==\n'
# A local STATE_DIR on Cloud Run keeps nothing, because nothing survives an
# execution. It is degraded rather than broken, so it warns rather than refusing.
d="$(scenario ephemeral_state)"
page "${d}" first "" 1201
pr_fresh "${d}" pr-1201.json
RUN_ENV=(CLOUD_RUN_EXECUTION=copilot-review-bot-abcde)
run "${d}"
assert_eq "exit status is 0, this is degraded not broken" 0 "${rc}"
assert_eq "the work still got done" 1 "$(calls "${d}/calls.log" request)"
assert_eq "and it warned about the state" 1 \
    "$(events "${d}/out.log" '.event=="state.ephemeral" and .severity=="WARNING"')"
run "${d}"
assert_eq "off Cloud Run it stays quiet" 0 "$(events "${d}/out.log" '.event=="state.ephemeral"')"

printf '\n== text log format still works for a terminal ==\n'
d="$(scenario text_format)"
page "${d}" first "" 1101
pr_fresh "${d}" pr-1101.json
run "${d}" --log-format text
assert_eq "exit status is 0" 0 "${rc}"
if grep -q 'INFO review.requested' "${d}/out.log"; then
    ok "logfmt lines are readable"
else
    bad "logfmt lines are readable" "$(head -3 "${d}/out.log")"
fi

# A value with spaces has to be quoted, or the line is not logfmt and an embedded
# newline would split one event across two lines.
if grep -qE 'detail="[^"]* [^"]*"' "${d}/out.log"; then
    ok "a value containing spaces is quoted"
else
    bad "a value containing spaces is quoted" \
        "$(grep -m1 review.requested "${d}/out.log")"
fi
assert_eq "no line was split" 0 "$(grep -cv '^[0-9]' "${d}/out.log")"

# ===========================================================================
printf '\n== a mention that succeeds gets a thumbs up ==\n'
# The headline feature. Every other mention scenario in this suite covers a
# failure, so without this the success path is unexecuted.
d="$(scenario mention_ok)"
page "${d}" first "" 201
pr_fresh "${d}" pr-201.json "${MENTION}"
run "${d}"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "one review request was filed" 1 "$(calls "${d}/calls.log" request)"
assert_eq "the mention got a thumbs up" 1 \
    "$(grep -c 'react.*IC_1.*THUMBS_UP' "${d}/calls.log")"
assert_eq "no error comment was posted" 0 "$(calls "${d}/calls.log" comment)"
assert_eq "it was attributed to the mention" 1 \
    "$(events "${d}/out.log" '.event=="review.requested" and .trigger=="mention"')"
assert_eq "no ERROR was logged" 0 "$(events "${d}/out.log" '.severity=="ERROR"')"
assert_eq "the marker records the head commit" "head1" \
    "$(jq -r '.["XRPLF/rippled#201"].head' "${d}/state/${STATE_SUB}/requested.json")"
assert_log_shape "${d}/out.log" "mention_ok"

# ===========================================================================
printf '\n== a mention on a PR that needs nothing gets eyes, not a request ==\n'
for case_name in already_reviewed pending; do
    if [[ "${case_name}" == already_reviewed ]]; then
        extra='{"reviews":{"nodes":[{"submittedAt":"2026-08-02T10:00:00Z",
                "author":{"__typename":"Bot","login":"copilot-pull-request-reviewer"},
                "commit":{"oid":"head1"}}]}}'
        want_reason=already_reviewed_head
    else
        extra='{"reviewRequests":{"nodes":[{"requestedReviewer":
                {"__typename":"Bot","login":"copilot-pull-request-reviewer"}}]}}'
        want_reason=request_pending
    fi
    d="$(scenario "mention_eyes_${case_name}")"
    page "${d}" first "" 202
    pr_fresh "${d}" pr-202.json \
        "$(jq -n --argjson a "${MENTION}" --argjson b "${extra}" '$a * $b')"
    # --verbose, because "nothing to do" is a DEBUG event.
    run "${d}" --verbose
    assert_eq "${case_name}: exit status is 0" 0 "${rc}"
    assert_eq "${case_name}: no request was filed" 0 "$(calls "${d}/calls.log" request)"
    assert_eq "${case_name}: the mention got eyes" 1 \
        "$(grep -c 'react.*IC_1.*EYES' "${d}/calls.log")"
    assert_eq "${case_name}: and it said why" 1 \
        "$(events "${d}/out.log" ".event==\"mention.no_action\" and .reason==\"${want_reason}\"")"
done

# ===========================================================================
printf '\n== every automatic skip guard actually stops the request ==\n'
# The decision-rule suite proves the jq fields. These prove the guards act on
# them: dropping any one of these checks would otherwise pass the whole suite.
copilot_review() { # <oid> <submitted-at>
    printf '{"reviews":{"nodes":[{"submittedAt":"%s","author":{"__typename":"Bot","login":"copilot-pull-request-reviewer"},"commit":{"oid":"%s"}}]}}' \
        "$2" "$1"
}

skip_case() { # <name> <expected-reason> <extra-json>
    local name="$1" reason="$2" extra="$3" dir
    dir="$(scenario "skip_${name}")"
    page "${dir}" first "" 301
    pr_fresh "${dir}" pr-301.json "${extra}"
    run "${dir}" --verbose
    assert_eq "${name}: exit status is 0" 0 "${rc}"
    assert_eq "${name}: no request was filed" 0 "$(calls "${dir}/calls.log" request)"
    assert_eq "${name}: skipped for the right reason" 1 \
        "$(events "${dir}/out.log" ".event==\"pr.skipped\" and .reason==\"${reason}\"")"
}

skip_case draft draft '{"isDraft":true}'
skip_case other_base other_base '{"baseRefName":"release-2.6"}'
skip_case pending request_pending \
    '{"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Bot","login":"copilot-pull-request-reviewer"}}]}}'
skip_case reviewed_head already_reviewed_head "$(copilot_review head1 2026-08-02T10:00:00Z)"
skip_case unresolved unresolved_threads "$(jq -n \
    --argjson r "$(copilot_review old1 2026-08-02T10:00:00Z)" '$r * {
    reviewThreads:{nodes:[{isResolved:false,isOutdated:false,
        opener:{nodes:[{author:{__typename:"Bot",login:"copilot-pull-request-reviewer"}}]},
        comments:{nodes:[]}}]}}')"

# A User account is not the reviewer bot even when its login is the bot's, so its
# review must not suppress anything. The login matches the list on purpose: __typename
# is the only thing that can reject this payload, so this is the case that fails if the
# Bot guard is ever dropped.
d="$(scenario human_named_copilot)"
page "${d}" first "" 302
pr_fresh "${d}" pr-302.json \
    '{"reviews":{"nodes":[{"submittedAt":"2026-08-02T10:00:00Z",
      "author":{"__typename":"User","login":"copilot-pull-request-reviewer"},"commit":{"oid":"head1"}}]}}'
run "${d}"
assert_eq "a human review does not count as Copilot's" 1 \
    "$(calls "${d}/calls.log" request)"

# ===========================================================================
printf '\n== a re-review is requested once new work lands ==\n'
# basis=position end to end: Copilot reviewed an earlier commit, its threads are
# resolved, and a non-merge commit has landed since.
d="$(scenario new_work)"
page "${d}" first "" 303
jq -n '{
    isDraft:false, baseRefName:"develop", headRefOid:"head2",
    reviews:{nodes:[{submittedAt:"2026-08-02T10:00:00Z",
        author:{__typename:"Bot",login:"copilot-pull-request-reviewer"},
        commit:{oid:"head1"}}]},
    reviewThreads:{nodes:[{isResolved:true,isOutdated:false,
        opener:{nodes:[{author:{__typename:"Bot",login:"copilot-pull-request-reviewer"}}]},
        comments:{nodes:[]}}]},
    commits:{nodes:[
        {commit:{oid:"head1",authoredDate:"2026-08-01T10:00:00Z",
            committedDate:"2026-08-01T10:00:00Z",parents:{totalCount:1}}},
        {commit:{oid:"head2",authoredDate:"2026-08-03T10:00:00Z",
            committedDate:"2026-08-03T10:00:00Z",parents:{totalCount:1}}}]}
}' >"${d}/pr-303.json"
run "${d}"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the re-review was requested" 1 "$(calls "${d}/calls.log" request)"
assert_eq "the basis was the commit position" 1 \
    "$(events "${d}/out.log" '.event=="review.requested" and .basis=="position" and .reason=="new_commits_after_reviewed"')"

# ===========================================================================
printf '\n== a repo-wide permanent failure halts instead of retrying every PR ==\n'
# A 403 on the review request is a repo-wide fact. Without a breaker the bot sent
# one unspaced failing request per open PR, every run, forever.
d="$(scenario permanent_storm)"
page "${d}" first "" 401 402 403 404 405
pr_fresh "${d}" pr-any.json
printf 'HTTP 403: Resource not accessible by integration\n' >"${d}/fail-request"
run "${d}"
assert_eq "exit status is 1" 1 "${rc}"
assert_eq "it stopped after the breaker threshold, not once per PR" 2 \
    "$(calls "${d}/calls.log" request)"
assert_eq "the halt was reported once, as an ERROR" 1 \
    "$(events "${d}/out.log" '.event=="requests.halted" and .severity=="ERROR"')"
assert_eq "and it named a remedy" 1 \
    "$(events "${d}/out.log" '.event=="requests.halted" and .remedy=="check_role_seat_and_reviewer"')"
# The reviewer is the third thing that makes a request fail repo-wide, and the only
# one the operator sets, so the halt carries it rather than making them find the
# run.start line for the same run.
assert_eq "and the reviewer it was asking for" 1 \
    "$(events "${d}/out.log" '.event=="requests.halted" and .reviewer=="copilot-pull-request-reviewer[bot]" and .reviewer_field=="botLogins"')"
assert_eq "run.done reports the halt" 1 \
    "$(events "${d}/out.log" '.event=="run.done" and .requests_halted==true and .halt_reason=="permanent_failures"')"
assert_eq "no marker was written for a failed request" 0 \
    "$([[ -f "${d}/state/${STATE_SUB}/requested.json" ]] && jq -r 'length' "${d}/state/${STATE_SUB}/requested.json" || printf 0)"

# ===========================================================================
printf '\n== failed requests consume the per-run budget ==\n'
# Counting only successes meant a failing repo never reached the cap and walked
# every PR.
d="$(scenario failed_requests_count)"
page "${d}" first "" 411 412 413
pr_fresh "${d}" pr-any.json
printf 'HTTP 403: Resource not accessible by integration\n' >"${d}/fail-request"
RUN_ENV=(MAX_CONSECUTIVE_PERMANENT=99)
run "${d}" --max-requests 2
assert_eq "the cap stopped it at two attempts" 2 "$(calls "${d}/calls.log" request)"
assert_eq "run.done counts attempts separately from successes" 1 \
    "$(events "${d}/out.log" '.event=="run.done" and .requests_attempted==2 and .requests_filed==0')"

# ===========================================================================
printf '\n== a bad option is rejected before any work starts ==\n'
bad_option_case() { # <label> <expected-reason> <args...>
    local label="$1" reason="$2" dir
    shift 2
    dir="$(scenario "badopt_$(printf '%s' "${label}" | tr -cd '[:alnum:]')")"
    page "${dir}" first "" 501
    pr_fresh "${dir}" pr-501.json
    run "${dir}" "$@"
    assert_eq "${label}: exit status is 2" 2 "${rc}"
    assert_eq "${label}: nothing was queried" 0 "$(calls "${dir}/calls.log" pr)"
    assert_eq "${label}: reported as ${reason}" 1 \
        "$(events "${dir}/out.log" ".event==\"run.fatal\" and .reason==\"${reason}\"")"
    assert_log_shape "${dir}/out.log" "${label}"
}

# An unbalanced paren would abort the whole run inside jq, with no event at all.
bad_option_case "--mention-handle 'foo('" bad_option --mention-handle 'foo('
# Every option that takes a value has to check for it, not just --mention-handle. Each
# arm has its own guard, so each arm needs its own case.
for opt in --repo --base --pr --state --reviewer --mention-handle \
    --mention-age --max-requests --log-format --explain; do
    bad_option_case "${opt} with no value" bad_option "${opt}"
done
# A leading @ silently matched nothing, forever.
bad_option_case "--mention-handle '@name'" bad_option --mention-handle '@xrplf-bot'
# A non-numeric --pr reached the log as a raw JSON number.
bad_option_case "--pr abc" bad_option --pr abc
# A swallowed flag is the likeliest --base mistake, and an unchecked value makes
# every PR skip at DEBUG, so the run reports success having done nothing.
bad_option_case "--base swallowing a flag" bad_option --base --verbose

# Every numeric setting that reaches an arithmetic context needs validating: bash
# evaluates the contents of a bare name there, so a bad value is not just ignored.
printf '\n== a numeric environment setting is validated too ==\n'
for var in GCS_MAX_ATTEMPTS GCS_RETRY_BASE_SECONDS GH_MAX_ATTEMPTS GH_RETRY_BASE_SECONDS; do
    d="$(scenario "envnum_${var}")"
    page "${d}" first "" 504
    pr_fresh "${d}" pr-504.json
    RUN_ENV=("${var}=not-a-number")
    run "${d}"
    assert_eq "${var}: exit status is 2" 2 "${rc}"
    assert_eq "${var}: nothing was queried" 0 "$(calls "${d}/calls.log" pr)"
    assert_eq "${var}: it named the setting" 1 \
        "$(events "${d}/out.log" '.event=="run.fatal" and .setting=="'"${var}"'"')"
done

printf '\n== a repo with an empty owner or name is refused, not queried ==\n'
# It is a fatal rather than a skip because the state path is derived from the
# two halves, so there is nothing this run could go on to do.
for bad_repo in /rippled XRPLF/ a/b/c 'not-a-repo'; do
    d="$(scenario "badrepo_$(printf '%s' "${bad_repo}" | tr -cd '[:alnum:]')")"
    page "${d}" first "" 506
    pr_fresh "${d}" pr-506.json
    : >"${d}/calls.log"
    rc=0
    env -i PATH="${d}/bin:${TOOL_PATH}:/usr/bin:/bin" HOME="${d}" FAKE_DIR="${d}" \
        "${BASE_ENV[@]}" \
        GH_TOKEN=stub-token STATE_DIR="${d}/state" SLEEP_BETWEEN_MUTATIONS=0 LOG_FORMAT=json \
        "${BASH_BIN}" "${BOT}" --repo "${bad_repo}" >"${d}/out.log" 2>&1 || rc=$?
    LAST_LOG="${d}/out.log"
    assert_eq "${bad_repo}: exit status is 2" 2 "${rc}"
    assert_eq "${bad_repo}: reported as invalid, naming the value" 1 \
        "$(events "${d}/out.log" ".event==\"run.fatal\" and .reason==\"bad_repo\" and .given==\"${bad_repo}\"")"
    assert_eq "${bad_repo}: nothing was queried" 0 "$(calls "${d}/calls.log" list)"
done

printf '\n== an unknown option is refused ==\n'
d="$(scenario unknown_option)"
page "${d}" first "" 503
pr_fresh "${d}" pr-503.json
run "${d}" --nonsense
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "nothing was queried" 0 "$(calls "${d}/calls.log" pr)"
assert_eq "it names the option" 1 \
    "$(events "${d}/out.log" '.event=="run.fatal" and (.message | test("--nonsense"))')"
assert_log_shape "${d}/out.log" "unknown_option"

# A list that names no login at all leaves every Copilot test answering false, so every
# reviewed PR would look unreviewed and be asked for a second review. An empty value is
# not in here on purpose: like every other setting, empty means "unset" and takes the
# default. Only a value that is all separators and blanks is a mistake with no reading.
logins_case=0
for bad_logins in ',' ' ' ' , ,'; do
    logins_case=$((logins_case + 1))
    d="$(scenario "badopt_logins_${logins_case}")"
    page "${d}" first "" 502
    pr_fresh "${d}" pr-502.json
    RUN_ENV=(COPILOT_LOGINS="${bad_logins}")
    run "${d}"
    assert_eq "COPILOT_LOGINS '${bad_logins}': exit status is 2" 2 "${rc}"
    assert_eq "COPILOT_LOGINS '${bad_logins}': reported once at startup" 1 \
        "$(events "${d}/out.log" '.event=="run.fatal" and .setting=="COPILOT_LOGINS"')"
    assert_eq "COPILOT_LOGINS '${bad_logins}': nothing was queried" 0 \
        "$(calls "${d}/calls.log" pr)"
done

# ===========================================================================
printf '\n== a login list is comma separated, with the blanks forgiven ==\n'
# The whole point of the format: an env var or a --set-env-vars value needs no shell
# quoting of brackets and quotes. A list that has to survive being typed by hand has
# to survive the spaces that come with it.
d="$(scenario logins_spaced)"
page "${d}" first "" 508
# Copilot has reviewed the head commit, so the run is only due a request if the
# reviewer's login failed to match, which is what the list here decides.
jq -n '{isDraft:false, baseRefName:"develop", headRefOid:"head1",
        commits:{nodes:[{commit:{oid:"head1",authoredDate:"2026-08-01T10:00:00Z",
            committedDate:"2026-08-01T10:00:00Z",parents:{totalCount:1}}}]},
        reviews:{nodes:[{author:{login:"Some-Copilot",__typename:"Bot"},
            submittedAt:"2026-08-02T10:00:00Z",commit:{oid:"head1"}}]}}' \
    >"${d}/pr-508.json"
RUN_ENV=(COPILOT_LOGINS=' some-copilot , github-copilot ')
run "${d}" -v
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the padded login still matched, so no request went out" 0 \
    "$(calls "${d}/calls.log" request)"
assert_eq "and it says the head commit was already reviewed" 1 \
    "$(events "${d}/out.log" '.event=="pr.skipped" and .reason=="already_reviewed_head"')"

# ===========================================================================
printf '\n== the repository is one setting, so the last one named wins ==\n'
# One process watches one repo, and the repo is a setting like any other here: --repo
# twice is last-wins, the same as a repeated --state or --mention-age. ${REPO} is the
# lower precedence of the two, because it is the deployment's default rather than what
# somebody just typed.
for label in flag env_overridden; do
    d="$(scenario "lastwins_${label}")"
    page "${d}" first ""
    case "${label}" in
        flag) repo_args=(--repo XRPLF/clio --repo XRPLF/rippled) ;;
        env_overridden) repo_args=(--repo XRPLF/rippled) ;;
    esac
    : >"${d}/calls.log"
    rc=0
    env -i PATH="${d}/bin:${TOOL_PATH}:/usr/bin:/bin" HOME="${d}" FAKE_DIR="${d}" \
        "${BASE_ENV[@]}" \
        GH_TOKEN=stub-token STATE_DIR="${d}/state" SLEEP_BETWEEN_MUTATIONS=0 \
        LOG_FORMAT=json REPO=XRPLF/clio \
        "${BASH_BIN}" "${BOT}" "${repo_args[@]}" >"${d}/out.log" 2>&1 || rc=$?
    LAST_LOG="${d}/out.log"
    assert_eq "${label}: exit status is 0" 0 "${rc}"
    assert_eq "${label}: the last repo named is the one watched" 1 \
        "$(events "${d}/out.log" '.event=="run.start" and .repo=="XRPLF/rippled"')"
    assert_eq "${label}: and the one it replaced is not mentioned" 0 \
        "$(events "${d}/out.log" '.repo=="XRPLF/clio"')"
    # The state path comes from the same value, so a repo that won the parse but lost
    # the split would show up here as a directory nobody asked for.
    assert_eq "${label}: the state went under that repo alone" "${d}/state/${STATE_SUB}" \
        "$(find "${d}/state" -mindepth 2 -maxdepth 2 -type d)"
done

printf '\n== the REPO variable names the repository when no argument does ==\n'
d="$(scenario repo_env)"
page "${d}" first "" 509
pr_fresh "${d}" pr-509.json
: >"${d}/calls.log"
rc=0
env -i PATH="${d}/bin:${TOOL_PATH}:/usr/bin:/bin" HOME="${d}" FAKE_DIR="${d}" \
    "${BASE_ENV[@]}" \
    GH_TOKEN=stub-token STATE_DIR="${d}/state" SLEEP_BETWEEN_MUTATIONS=0 \
    LOG_FORMAT=json REPO=XRPLF/rippled \
    "${BASH_BIN}" "${BOT}" >"${d}/out.log" 2>&1 || rc=$?
LAST_LOG="${d}/out.log"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "run.start names the one repo" 1 \
    "$(events "${d}/out.log" '.event=="run.start" and .repo=="XRPLF/rippled"')"
assert_eq "and it did the work" 1 "$(calls "${d}/calls.log" request)"

# ===========================================================================
printf '\n== the marker file is only called corrupt when it is ==\n'
d="$(scenario marker_empty)"
page "${d}" first "" 601
pr_fresh "${d}" pr-601.json
printf '{}' >"${d}/state/${STATE_SUB}/requested.json"
run "${d}" --verbose
assert_eq "an empty marker object is not reported as unreadable" 0 \
    "$(events "${d}/out.log" '.event=="state.unreadable"')"
assert_eq "and it loaded zero markers" 1 \
    "$(events "${d}/out.log" '.event=="state.loaded" and .markers==0')"

d="$(scenario marker_corrupt)"
page "${d}" first "" 602
pr_fresh "${d}" pr-602.json
printf 'not json at all' >"${d}/state/${STATE_SUB}/requested.json"
run "${d}"
assert_eq "a corrupt marker file still warns" 1 \
    "$(events "${d}/out.log" '.event=="state.unreadable" and .severity=="WARNING"')"
assert_eq "and the run carries on" 0 "${rc}"

# ===========================================================================
printf '\n== a repo read failure is diagnosed, not just reported ==\n'
# diagnose_access runs on every repo-read failure, which is exactly when the
# operator is reading the log, and none of its arms had any coverage.
diagnose_case() { # <label> <stub-stderr> <expected-event> [extra-env...]
    local label="$1" err="$2" want="$3" dir
    shift 3
    dir="$(scenario "diag_${label}")"
    # Fail the PR list by making the stub reject that query.
    cat >"${dir}/bin/gh" <<STUB
#!/usr/bin/env bash
[[ "\${1:-}" == auth ]] && exit 0
for a in "\$@"; do
    case "\${a}" in
        query=*'viewer { login }'*) printf 'xrplf-bot\n'; exit 0 ;;
    esac
done
printf '%s\n' "${err}" >&2
exit 1
STUB
    chmod +x "${dir}/bin/gh"
    RUN_ENV=("$@")
    run "${dir}"
    assert_eq "${label}: exit status is 1" 1 "${rc}"
    assert_eq "${label}: emitted ${want}" 1 \
        "$(events "${dir}/out.log" ".event==\"${want}\"")"
    assert_log_shape "${dir}/out.log" "diag_${label}"
}

diagnose_case bad_credentials 'HTTP 401: Bad credentials' access.token_rejected
diagnose_case saml 'HTTP 403: Although you appear to have the correct authorization credentials, the organization has enabled SAML single sign-on' access.sso_required
diagnose_case fine_grained 'HTTP 404: Could not resolve to a Repository' \
    access.fine_grained_pat GH_TOKEN=github_pat_11ABCDEF

# ===========================================================================
printf '\n== a degraded GitHub ends the sweep instead of grinding through it ==\n'
# Each failed read costs three attempts and nine seconds of sleeping. Walking a
# whole repo that way outlasts any sane task timeout.
d="$(scenario read_breaker)"
page "${d}" first "" 701 702 703 704 705 706
pr_fresh "${d}" pr-any.json
printf 'HTTP 502: Bad Gateway\n' >"${d}/fail-pr"
run "${d}"
assert_eq "exit status is 1" 1 "${rc}"
# Distinct PRs, because each failed read is retried three times inside gql().
assert_eq "it stopped at the breaker, not after all six PRs" 3 \
    "$(grep '^pr	' "${d}/calls.log" | cut -f2 | sort -u | grep -c .)"
assert_eq "the halt was reported" 1 \
    "$(events "${d}/out.log" '.event=="reads.halted" and .severity=="ERROR"')"
assert_eq "each failed read was reported" 3 \
    "$(events "${d}/out.log" '.event=="pr.read_failed"')"
assert_eq "the halt carries a reason a filter can match" 1 \
    "$(events "${d}/out.log" '.event=="reads.halted" and .reason=="read_failures"')"
assert_log_shape "${d}/out.log" "read_breaker"

# ===========================================================================
printf '\n== a sweep stopped by read failures does not blame the request cap ==\n'
# Three conditions set stop_scanning: the cap, the read breaker and the deadline. Only
# the cap has a halt_reason, so a run the breaker stopped reported "the run limit of 25
# review requests is reached" with zero requests attempted, which sent anyone reading
# the log after an outage looking at the wrong thing. run.done is what carries that to
# a dashboard, so that is what this asserts on.
d="$(scenario stop_reason)"
page "${d}" first "" 741 742 743
pr_fresh "${d}" pr-any.json
printf 'HTTP 502: Bad Gateway\n' >"${d}/fail-pr"
run "${d}"
assert_eq "exit status is 1" 1 "${rc}"
assert_eq "no request was ever attempted" 0 "$(calls "${d}/calls.log" request)"
assert_eq "run.done names why it stopped early" 1 \
    "$(events "${d}/out.log" '.event=="run.done" and .stopped_early==true and .stop_reason=="read_failures"')"
assert_eq "and not the cap it never reached" 0 \
    "$(events "${d}/out.log" '.event=="run.done" and .stop_reason=="run_limit"')"
assert_eq "nothing claims the run limit was reached" 0 \
    "$(events "${d}/out.log" '(.message // "")|test("run limit")')"

# ===========================================================================
printf '\n== repeated transient request failures halt the run, without a reaction ==\n'
d="$(scenario transient_storm)"
page "${d}" first "" 711 712 713 714
pr_fresh "${d}" pr-any.json
printf 'HTTP 502: Bad Gateway\n' >"${d}/fail-request"
run "${d}"
assert_eq "exit status is 0, because a retry is the remedy" 0 "${rc}"
assert_eq "it halted at the transient threshold" 3 "$(calls "${d}/calls.log" request)"
assert_eq "the halt is a WARNING, not an ERROR" 1 \
    "$(events "${d}/out.log" '.event=="requests.halted" and .severity=="WARNING"')"
assert_eq "run.done names the reason" 1 \
    "$(events "${d}/out.log" '.event=="run.done" and .halt_reason=="transient_failures"')"
assert_eq "no ERROR was logged" 0 "$(events "${d}/out.log" '.severity=="ERROR"')"

printf '\n== and TRANSIENT_FAILURES_ARE_ERRORS makes them visible to alerting ==\n'
d="$(scenario transient_as_error)"
page "${d}" first "" 715
pr_fresh "${d}" pr-715.json
printf 'HTTP 502: Bad Gateway\n' >"${d}/fail-request"
RUN_ENV=(TRANSIENT_FAILURES_ARE_ERRORS=true)
run "${d}"
assert_eq "exit status is 1 when asked for" 1 "${rc}"

# ===========================================================================
printf '\n== a reaction that fails does not take the run down with it ==\n'
d="$(scenario react_transient)"
page "${d}" first "" 721
pr_fresh "${d}" pr-721.json "${MENTION}"
printf 'HTTP 502: Bad Gateway\n' >"${d}/fail-react"
run "${d}"
assert_eq "a transient reaction failure is not an error" 0 "${rc}"
assert_eq "it was classified transient" 1 \
    "$(events "${d}/out.log" '.event=="reaction.failed" and .failure_class=="transient" and .retryable==true')"

d="$(scenario react_permanent)"
page "${d}" first "" 722
pr_fresh "${d}" pr-722.json "${MENTION}"
printf 'HTTP 422: Unprocessable Entity\n' >"${d}/fail-react"
run "${d}"
assert_eq "a permanent reaction failure fails the run" 1 "${rc}"
assert_eq "and it was classified permanent" 1 \
    "$(events "${d}/out.log" '.event=="reaction.failed" and .failure_class=="permanent"')"

printf '\n== a duplicate reaction is not worth escalating ==\n'
d="$(scenario react_duplicate)"
page "${d}" first "" 723
pr_fresh "${d}" pr-723.json "${MENTION}"
printf 'Reaction has already been taken\n' >"${d}/fail-react"
run "${d}" --verbose
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "it was noted, not warned about" 1 \
    "$(events "${d}/out.log" '.event=="reaction.exists"')"

printf '\n== a failed error-comment is reported but does not mask the request failure ==\n'
d="$(scenario comment_fails)"
page "${d}" first "" 724
pr_fresh "${d}" pr-724.json "${MENTION}"
printf 'HTTP 403: Resource not accessible by integration\n' >"${d}/fail-request"
printf 'HTTP 403: Resource not accessible by integration\n' >"${d}/fail-comment"
run "${d}"
assert_eq "exit status is 1" 1 "${rc}"
assert_eq "the comment failure was reported" 1 \
    "$(events "${d}/out.log" '.event=="comment.failed"')"
assert_eq "and the request failure still is too" 1 \
    "$(events "${d}/out.log" '.event=="review.request_failed" and .severity=="ERROR"')"

# ===========================================================================
printf '\n== a PR that vanishes between the list and the read is reported ==\n'
# The event names what was observed rather than a cause. The same guard fires for a PR
# that is gone, for a repository renamed mid-sweep, and for any response that is not
# the expected shape, so repository_present is what tells them apart.
d="$(scenario pr_gone)"
page "${d}" first "" 731
touch "${d}/null-pr"
run "${d}"
assert_eq "exit status is 1" 1 "${rc}"
assert_eq "it said which PR" 1 \
    "$(events "${d}/out.log" '.event=="pr.read_unexpected" and .pr==731')"
assert_eq "and that the repository itself was still there" 1 \
    "$(events "${d}/out.log" '.event=="pr.read_unexpected" and .repository_present==true')"

# ===========================================================================
printf '\n== the run stops at its own deadline rather than being killed ==\n'
# Being SIGKILLed by the platform costs the lock for the rest of its TTL, which
# is worse than stopping one tick short.
d="$(scenario deadline)"
page "${d}" first "" 741 742 743 744 745
pr_fresh "${d}" pr-any.json
RUN_ENV=(RUN_DEADLINE_SECONDS=1 SLEEP_BETWEEN_MUTATIONS=1)
run "${d}"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "it stopped at the deadline" 1 \
    "$(events "${d}/out.log" '.event=="repo.stopped" and .reason=="run_deadline"')"
assert_eq "run.done records that" 1 \
    "$(events "${d}/out.log" '.event=="run.done" and .deadline_reached==true')"

# ===========================================================================
printf '\n== the remaining basis arms are spelled out in the log ==\n'
# basis=authored: the branch was rewritten and commits on it postdate the review.
d="$(scenario basis_authored)"
page "${d}" first "" 751
jq -n '{
    isDraft:false, baseRefName:"develop", headRefOid:"new1",
    reviews:{nodes:[{submittedAt:"2026-08-02T10:00:00Z",
        author:{__typename:"Bot",login:"copilot-pull-request-reviewer"},
        commit:{oid:"gone1"}}]},
    commits:{nodes:[{commit:{oid:"new1",authoredDate:"2026-08-05T10:00:00Z",
        committedDate:"2026-08-05T10:00:00Z",parents:{totalCount:1}}}]}
}' >"${d}/pr-751.json"
run "${d}"
assert_eq "a rewritten branch with newer work is requested" 1 \
    "$(calls "${d}/calls.log" request)"
assert_eq "and the basis is recorded as authored" 1 \
    "$(events "${d}/out.log" '.event=="review.requested" and .basis=="authored" and .reason=="new_commits_authored_after_review"')"

# basis=rewritten: a restack, only requested when the operator opts in.
d="$(scenario basis_rewritten)"
page "${d}" first "" 752
jq -n '{
    isDraft:false, baseRefName:"develop", headRefOid:"new2",
    reviews:{nodes:[{submittedAt:"2026-08-10T10:00:00Z",
        author:{__typename:"Bot",login:"copilot-pull-request-reviewer"},
        commit:{oid:"gone2"}}]},
    commits:{nodes:[{commit:{oid:"new2",authoredDate:"2026-08-01T10:00:00Z",
        committedDate:"2026-08-11T10:00:00Z",parents:{totalCount:1}}}]}
}' >"${d}/pr-752.json"
run "${d}" --verbose
assert_eq "a restack alone is not new work" 0 "$(calls "${d}/calls.log" request)"
assert_eq "and it says why" 1 \
    "$(events "${d}/out.log" '.event=="pr.skipped" and .reason=="rewritten_without_new_work"')"
cp "${d}/pr-752.json" "${d}/pr-752.keep"
RUN_ENV=(REWRITE_TRIGGERS_REVIEW=true)
run "${d}"
assert_eq "REWRITE_TRIGGERS_REVIEW=true opts in" 1 "$(calls "${d}/calls.log" request)"
assert_eq "and the basis is recorded as rewritten" 1 \
    "$(events "${d}/out.log" '.event=="review.requested" and .reason=="rewritten_counted_as_new_work"')"

# ===========================================================================
printf '\n== a malformed PR payload is reported per PR, not fatal ==\n'
d="$(scenario bad_payload)"
page "${d}" first "" 761
# Valid JSON of the wrong shape: JQ_DECIDE maps over .reviews.nodes, so a number
# there is a jq runtime error rather than a parse error.
printf '{"reviews":{"nodes":5}}\n' >"${d}/pr-761.json"
run "${d}"
assert_eq "the payload failure was reported" 1 \
    "$(events "${d}/out.log" '.event=="pr.evaluate_failed"')"
assert_eq "exit status is 1" 1 "${rc}"
assert_eq "the run still finished" 1 "$(events "${d}/out.log" '.event=="run.done"')"

# ===========================================================================
printf '\n== a missing prerequisite is reported once, with a fix ==\n'
d="$(scenario no_jq)"
mkdir -p "${d}/onlybin"
ln -sf "$(command -v bash)" "${d}/onlybin/bash" 2>/dev/null || true
rc=0
env -i PATH="${d}/bin:${d}/onlybin" HOME="${d}" FAKE_DIR="${d}" \
    "${BASE_ENV[@]}" \
    GH_TOKEN=stub-token STATE_DIR="${d}/state" LOG_FORMAT=json \
    "${BASH_BIN}" "${BOT}" --repo XRPLF/rippled >"${d}/out.log" 2>&1 || rc=$?
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "the missing programs are listed" 1 \
    "$(events "${d}/out.log" '.event=="run.fatal" and .reason=="missing_prerequisites"')"
if grep -q 'run.prerequisite_missing' "${d}/out.log"; then
    ok "and each one comes with an install hint"
else
    bad "and each one comes with an install hint" "$(cat "${d}/out.log")"
fi

# ===========================================================================
printf '\n== bad settings are refused with a clear complaint ==\n'
setting_case() { # <label> <env> <expected-setting>
    local label="$1" envv="$2" want="$3" dir
    dir="$(scenario "set_$(printf '%s' "${label}" | tr -cd '[:alnum:]')")"
    page "${dir}" first "" 771
    pr_fresh "${dir}" pr-771.json
    RUN_ENV=("${envv}")
    run "${dir}"
    assert_eq "${label}: exit status is 2" 2 "${rc}"
    assert_eq "${label}: named the setting" 1 \
        "$(events "${dir}/out.log" ".event==\"run.fatal\" and .setting==\"${want}\"")"
}
setting_case "a non-numeric sleep" SLEEP_BETWEEN_MUTATIONS=soon SLEEP_BETWEEN_MUTATIONS
setting_case "a non-boolean flag" IGNORE_OUTDATED=yes IGNORE_OUTDATED
setting_case "a non-numeric deadline" RUN_DEADLINE_SECONDS=later RUN_DEADLINE_SECONDS

printf '\n== an unknown log format is refused, and still logs as JSON ==\n'
d="$(scenario bad_format)"
page "${d}" first "" 772
pr_fresh "${d}" pr-772.json
run "${d}" --log-format yaml
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "the complaint itself is still parseable" 1 \
    "$(events "${d}/out.log" '.event=="run.fatal" and .reason=="bad_log_format"')"

# ===========================================================================
printf '\n== --state, --help and --version behave ==\n'
d="$(scenario state_flag)"
page "${d}" first "" 781
pr_fresh "${d}" pr-781.json
mkdir -p "${d}/elsewhere"
run "${d}" --state "${d}/elsewhere"
assert_eq "exit status is 0" 0 "${rc}"
if [[ -f "${d}/elsewhere/${STATE_SUB}/requested.json" ]]; then
    ok "--state puts the markers where it was told"
else
    bad "--state puts the markers where it was told" "$(ls -R "${d}/elsewhere")"
fi

help_out="$("${BASH_BIN}" "${BOT}" --help 2>&1)" || true
assert_contains "--help lists the options" "--max-requests" "${help_out}"
assert_contains "--help mentions --version" "--version" "${help_out}"
# The block is printed by seding it out of the script, and a sed range ends *on*
# the line it matches, so ranging to the "Exit status" heading printed the heading
# and dropped the sentences under it. Those sentences are the exit-code semantics,
# which is the part somebody wiring up alerting needs.
assert_contains "--help explains exit code 2" "fatal/usage" "${help_out}"
assert_contains "--help explains the transient case" "TRANSIENT_FAILURES_ARE_ERRORS" "${help_out}"
assert_eq "--help ends with a complete sentence" "." "${help_out: -1}"
# The section dividers are part of the source comment, not the help text.
assert_eq "--help prints no comment dividers" 0 \
    "$(grep -c -- '^---' <<<"${help_out}")"
version_out="$("${BASH_BIN}" "${BOT}" --version 2>&1)" || true
assert_contains "--version prints a version" "copilot-review-bot.sh" "${version_out}"

# ===========================================================================
printf '\n== a dry run answers a mention without touching anything ==\n'
d="$(scenario dry_mention)"
page "${d}" first "" 811
pr_fresh "${d}" pr-811.json "${MENTION}"
run "${d}" --verbose --dry-run
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "no reaction was sent" 0 "$(calls "${d}/calls.log" react)"
assert_eq "but it said what it would have done" 1 \
    "$(events "${d}/out.log" '.event=="reaction.added" and .dry_run==true')"
assert_eq "and no request went out" 0 "$(calls "${d}/calls.log" request)"
if [[ -f "${d}/state/${STATE_SUB}/requested.json" ]]; then
    bad "a dry run writes no markers" "requested.json was created"
else
    ok "a dry run writes no markers"
fi
if [[ -e "${d}/state/${STATE_SUB}/lock" ]]; then
    bad "a dry run takes no lock" "the lock file was created"
else
    ok "a dry run takes no lock"
fi
assert_eq "and it says why" 1 \
    "$(events "${d}/out.log" '.event=="lock.skipped" and .reason=="dry_run"')"

printf '\n== a dry run reports the comment it would have posted ==\n'
d="$(scenario dry_comment)"
page "${d}" first "" 812
pr_fresh "${d}" pr-812.json "${MENTION}"
printf 'HTTP 403: Resource not accessible by integration\n' >"${d}/fail-request"
run "${d}" --dry-run
assert_eq "no comment was posted" 0 "$(calls "${d}/calls.log" comment)"
assert_eq "exit status is 0, nothing was attempted" 0 "${rc}"

# ===========================================================================
printf '\n== an unwritable state directory is reported, not ignored ==\n'
# The markers are a cache, so this degrades rather than failing the work, but it
# has to be visible: silently losing them means re-filing requests every run.
d="$(scenario state_unwritable)"
page "${d}" first "" 821
pr_fresh "${d}" pr-821.json
mkdir -p "${d}/lockdir"
# The innermost directory, not ${d}/state: that one has to stay writable, or the
# run fails earlier on creating the per-repo directory below it and never reaches
# the marker write this case is about.
chmod 500 "${d}/state/${STATE_SUB}"
# The lock lives outside the read-only directory, so the run gets as far as
# writing the markers. That is the failure under test.
RUN_ENV=(LOCK_FILE="${d}/lockdir/lock")
run "${d}"
chmod 700 "${d}/state/${STATE_SUB}"
assert_eq "the request still went out" 1 "$(calls "${d}/calls.log" request)"
assert_eq "the write failure was reported" 1 \
    "$(events "${d}/out.log" '.event=="state.write_failed" and .severity=="ERROR"')"
assert_eq "and the run exits 1 so it is noticed" 1 "${rc}"
# The contract this case is named for: a failure here is an event, not a raw shell
# message. `>file` prints "Permission denied" from the shell itself, so a guard
# whose 2>/dev/null comes after the failing redirect does not suppress it.
assert_log_shape "${d}/out.log" state_unwritable

# ===========================================================================
printf '\n== an unwritable lock path refuses to run unlocked ==\n'
d="$(scenario lock_unwritable)"
page "${d}" first "" 822
pr_fresh "${d}" pr-822.json
mkdir -p "${d}/nolock"
chmod 500 "${d}/nolock"
RUN_ENV=(LOCK_FILE="${d}/nolock/sub/lock")
run "${d}"
chmod 700 "${d}/nolock"
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "nothing was queried" 0 "$(calls "${d}/calls.log" pr)"
assert_eq "it said the lock could not be created" 1 \
    "$(events "${d}/out.log" '.event=="run.fatal" and .reason=="lock_unwritable"')"
assert_log_shape "${d}/out.log" "lock_unwritable"

# ===========================================================================
printf '\n== an aborted run says so instead of just stopping ==\n'
# Without a signal trap the log simply ends, which is indistinguishable from a
# run that never started.
d="$(scenario aborted)"
page "${d}" first "" 801 802 803 804 805 806 807 808
pr_fresh "${d}" pr-any.json
: >"${d}/calls.log"
env -i PATH="${d}/bin:${TOOL_PATH}:/usr/bin:/bin" HOME="${d}" FAKE_DIR="${d}" \
    "${BASE_ENV[@]}" \
    GH_TOKEN=stub-token STATE_DIR="${d}/state" SLEEP_BETWEEN_MUTATIONS=2 LOG_FORMAT=json \
    "${BASH_BIN}" "${BOT}" --repo XRPLF/rippled >"${d}/out.log" 2>&1 &
bot_pid=$!
sleep 2
kill -TERM "${bot_pid}" 2>/dev/null || true
wait "${bot_pid}" 2>/dev/null || rc=$?
assert_eq "it reported the abort" 1 \
    "$(events "${d}/out.log" '.event=="run.aborted" and .reason=="signal"')"
assert_eq "and named the signal" 1 \
    "$(events "${d}/out.log" '.event=="run.aborted" and .signal=="SIGTERM"')"

# ===========================================================================
printf '\n== an unexpected error inside a function still reports itself ==\n'
# `set -e` without `-E` does not inherit the ERR trap into function bodies, and
# almost everything here runs inside one, so this event was unreachable: the run
# ended mid-sweep with no terminal event at all and an undocumented exit status.
# A failing mkdir stands in for the real trigger, a full or read-only filesystem.
d="$(scenario unexpected_error)"
page "${d}" first "" 831
pr_fresh "${d}" pr-831.json
cat >"${d}/bin/mkdir" <<'STUB'
#!/usr/bin/env bash
# Fail only for the per-repo payload directory, so the state directory the
# harness needs is still created.
[[ "$*" == *"-rippled"* ]] && exit 1
exec /bin/mkdir "$@"
STUB
chmod +x "${d}/bin/mkdir"
run "${d}"
assert_eq "it reported the abort" 1 \
    "$(events "${d}/out.log" '.event=="run.aborted" and .reason=="unexpected_error"')"
assert_eq "at ERROR, with the line it died on" 1 \
    "$(events "${d}/out.log" '.event=="run.aborted" and .severity=="ERROR" and (.line|type)=="number"')"
assert_eq "the exit status is the documented fatal one" 2 "${rc}"
assert_log_shape "${d}/out.log" unexpected_error

# ===========================================================================
printf '\n== --pr will not act on a pull request that is not open ==\n'
# The sweep lists OPEN only, but --pr bypasses the list, so without the state
# field a merged PR could have a review requested on it.
#
# The payload also carries a mention, because the state gate has to sit above the
# mention handling and not just above the request: a merged PR cannot be reviewed, so
# neither a request nor a reaction belongs on one. Nothing else pins that order.
d="$(scenario pr_closed)"
page "${d}" first "" 841
pr_fresh "${d}" pr-841.json "$(jq -n --argjson m "${MENTION}" '$m * {state:"MERGED"}')"
run "${d}" --pr 841 --verbose
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "no request went out" 0 "$(calls "${d}/calls.log" request)"
assert_eq "the mention was not answered either" 0 "$(calls "${d}/calls.log" react)"
assert_eq "and no comment was posted" 0 "$(calls "${d}/calls.log" comment)"
assert_eq "it said why" 1 \
    "$(events "${d}/out.log" '.event=="pr.skipped" and .reason=="not_open" and .state=="MERGED"')"

printf '\n== an open PR reached through --pr is still acted on ==\n'
# --pr bypasses the PR list, so it looks the default branch up separately. That
# lookup and its failure handling are only reachable this way.
d="$(scenario pr_open)"
page "${d}" first "" 842
pr_fresh "${d}" pr-842.json
run "${d}" --pr 842
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the request went out" 1 "$(calls "${d}/calls.log" request)"
assert_eq "only the named PR was fetched" 1 "$(calls "${d}/calls.log" pr)"

printf '\n== --pr with an explicit --base skips the default-branch lookup ==\n'
d="$(scenario pr_with_base)"
pr_fresh "${d}" pr-843.json
run "${d}" --pr 843 --base develop
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the request went out" 1 "$(calls "${d}/calls.log" request)"
assert_eq "the repository was never listed" 0 "$(calls "${d}/calls.log" list)"

printf '\n== --pr reports a repository it cannot read ==\n'
d="$(scenario pr_repo_unreadable)"
pr_fresh "${d}" pr-844.json
printf 'HTTP 404: Could not resolve to a Repository\n' >"${d}/fail-page-first"
run "${d}" --pr 844
assert_eq "exit status is 1" 1 "${rc}"
assert_eq "it reported the repository read, not the PR" 1 \
    "$(events "${d}/out.log" '.event=="repo.read_failed"')"
assert_eq "and diagnosed the access failure" 1 \
    "$(events "${d}/out.log" '.event=="access.denied"')"

# ===========================================================================
printf '\n== a --base that no PR targets is called out, not silently ignored ==\n'
# Every PR skipping for the base branch is indistinguishable from a healthy run
# with nothing to do, and the per-PR reason is only visible under --verbose.
d="$(scenario base_matches_nothing)"
page "${d}" first "" 851 852
pr_fresh "${d}" pr-any.json
run "${d}" --base no-such-branch
assert_eq "exit status is 0, this is a warning not a failure" 0 "${rc}"
assert_eq "no request went out" 0 "$(calls "${d}/calls.log" request)"
assert_eq "it warned that the base matches nothing" 1 \
    "$(events "${d}/out.log" '.event=="repo.no_matching_base" and .severity=="WARNING"')"
assert_eq "and named the branch it was given" 1 \
    "$(events "${d}/out.log" '.event=="repo.no_matching_base" and .expected_base=="no-such-branch"')"

printf '\n== the right base branch does not trigger that warning ==\n'
d="$(scenario base_matches)"
page "${d}" first "" 861
pr_fresh "${d}" pr-861.json
run "${d}"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "no warning" 0 "$(events "${d}/out.log" '.event=="repo.no_matching_base"')"
assert_eq "and the request went out" 1 "$(calls "${d}/calls.log" request)"

# ===========================================================================
printf '\n== gh writing to stderr while exiting 0 does not corrupt a read ==\n'
# GH_DEBUG=api makes gh log HTTP traffic to stderr and still exit 0. Merging the
# streams into the captured output made the first thing jq saw "* Request at ...",
# so the run died inside a function with only run.start logged and exit 5.
d="$(scenario gh_stderr_noise)"
page "${d}" first "" 871
pr_fresh "${d}" pr-871.json
mv "${d}/bin/gh" "${d}/bin/gh-real"
cat >"${d}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '* Request at 2026-08-29 07:34:59\n* Request to https://api.github.com/graphql\n' >&2
exec "$(dirname "$0")/gh-real" "$@"
STUB
chmod +x "${d}/bin/gh"
run "${d}"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the request still went out" 1 "$(calls "${d}/calls.log" request)"
assert_eq "a terminal event was emitted" 1 "$(events "${d}/out.log" '.event=="run.done"')"
assert_log_shape "${d}/out.log" gh_stderr_noise

printf '\n== a GraphQL error is summarized without the response body ==\n'
# gh prints the whole response on stdout and its own message on stderr, then exits
# 1. Merging them put up to 400 characters of PR comment text in the `error` field
# and pushed the actual message out of the window.
d="$(scenario graphql_error)"
page "${d}" first "" 881
pr_fresh "${d}" pr-881.json
mv "${d}/bin/gh" "${d}/bin/gh-real"
cat >"${d}/bin/gh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
    case "${a}" in
        *reviewThreads*)
            # Logged here, because this arm never reaches the real stub that
            # normally records the call, and the point is to count attempts.
            printf 'pr\tgraphql-error\n' >>"${FAKE_DIR}/calls.log"
            printf '{"data":{"repository":{"pullRequest":{"body":"CONFIDENTIAL-PADDING"}}},'
            printf '"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a PullRequest"}]}'
            printf 'gh: Could not resolve to a PullRequest\n' >&2
            exit 1
            ;;
    esac
done
exec "$(dirname "$0")/gh-real" "$@"
STUB
chmod +x "${d}/bin/gh"
run "${d}"
assert_eq "exit status is 1" 1 "${rc}"
assert_eq "the error field carries gh's message" 1 \
    "$(events "${d}/out.log" '.event=="pr.read_failed" and (.error|test("Could not resolve"))')"
assert_eq "and not the response body" 0 \
    "$(events "${d}/out.log" '.event=="pr.read_failed" and (.error|test("CONFIDENTIAL"))')"
# A settled NOT_FOUND is not worth three attempts and nine seconds of sleeping.
assert_eq "a settled GraphQL error is not retried" 1 "$(calls "${d}/calls.log" pr)"

# ===========================================================================
printf '\n== a later page failing to read is reported, not silently dropped ==\n'
d="$(scenario page_two_fails)"
page "${d}" first c2 901 902
pr_fresh "${d}" pr-any.json
printf 'HTTP 500: Internal Server Error\n' >"${d}/fail-page-c2"
run "${d}"
assert_eq "exit status is 1" 1 "${rc}"
assert_eq "it said which page failed" 1 \
    "$(events "${d}/out.log" '.event=="repo.list_failed" and .page=="subsequent"')"
assert_log_shape "${d}/out.log" page_two_fails

printf '\n== an unparseable hasNextPage stops the sweep loudly ==\n'
# `[[ "$(jq ...)" == true ]]` would read anything that is not the literal "true"
# as "no more pages" and truncate a busy repo in silence.
d="$(scenario bad_has_next)"
jq -n '{data:{repository:{defaultBranchRef:{name:"develop"},
    pullRequests:{pageInfo:{hasNextPage:null,endCursor:null},nodes:[{number:911}]}}}}' \
    >"${d}/page-first.json"
pr_fresh "${d}" pr-911.json
run "${d}"
assert_eq "exit status is 1" 1 "${rc}"
assert_eq "it reported the pagination fault" 1 \
    "$(events "${d}/out.log" '.event=="repo.list_failed" and .page=="pagination"')"

printf '\n== a repo with no default branch is reported ==\n'
d="$(scenario no_base_branch)"
jq -n '{data:{repository:{defaultBranchRef:null,
    pullRequests:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{number:921}]}}}}' \
    >"${d}/page-first.json"
pr_fresh "${d}" pr-921.json
run "${d}"
assert_eq "exit status is 1" 1 "${rc}"
assert_eq "it said the base branch could not be determined" 1 \
    "$(events "${d}/out.log" '.event=="repo.no_base_branch"')"
assert_eq "and no PR was fetched" 0 "$(calls "${d}/calls.log" pr)"

# ===========================================================================
printf '\n== refusing to run unlocked when flock cannot be executed ==\n'
# "command not found" is exit 127, which is indistinguishable from "the lock is
# held" unless it is checked, so a missing flock turned every run into a no-op.
d="$(scenario flock_missing)"
page "${d}" first "" 951
pr_fresh "${d}" pr-951.json
cat >"${d}/bin/flock" <<'STUB'
#!/usr/bin/env bash
exit 127
STUB
chmod +x "${d}/bin/flock"
run "${d}"
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "it refused rather than reporting a held lock" 1 \
    "$(events "${d}/out.log" '.event=="run.fatal" and .reason=="flock_unusable"')"
assert_eq "nothing was queried" 0 "$(calls "${d}/calls.log" pr)"

# ===========================================================================
printf '\n== a gs:// state dir with no bucket is refused ==\n'
d="$(scenario gs_no_bucket)"
page "${d}" first "" 961
pr_fresh "${d}" pr-961.json
RUN_ENV=(STATE_DIR="gs://")
run "${d}"
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "it named the bad value" 1 \
    "$(events "${d}/out.log" '.event=="run.fatal" and .reason=="bad_state_dir"')"

# ===========================================================================
printf '\n== no credentials at all is a fatal, before any work ==\n'
d="$(scenario no_credentials)"
page "${d}" first "" 971
pr_fresh "${d}" pr-971.json
# The stub gh answers `auth` with 0, so it has to be made to fail for this path.
cat >"${d}/bin/gh" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == auth ]] && exit 1
exit 1
STUB
chmod +x "${d}/bin/gh"
RUN_ENV=(GH_TOKEN= GITHUB_TOKEN=)
run "${d}"
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "it said there were no credentials" 1 \
    "$(events "${d}/out.log" '.event=="run.fatal" and .reason=="no_credentials"')"

# ===========================================================================
printf '\n== a branch refreshed from base only is left alone ==\n'
# The documented "only merge commits since the review" row of the decision table,
# end to end. Pulling the base branch in must never trigger a review.
d="$(scenario merge_only)"
page "${d}" first "" 981
jq -n '{isDraft:false, baseRefName:"develop", headRefOid:"merge1",
    author:{login:"alice"},
    reviews:{nodes:[{submittedAt:"2026-08-02T00:00:00Z",
        author:{__typename:"Bot",login:"copilot-pull-request-reviewer"},
        commit:{oid:"work1"}}]},
    commits:{nodes:[
        {commit:{oid:"work1",authoredDate:"2026-08-01T10:00:00Z",parents:{totalCount:1}}},
        {commit:{oid:"merge1",authoredDate:"2026-08-03T10:00:00Z",parents:{totalCount:2}}}]}}' \
    >"${d}/pr-981.json"
run "${d}" --verbose
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "no request went out" 0 "$(calls "${d}/calls.log" request)"
assert_eq "it said why, naming the basis" 1 \
    "$(events "${d}/out.log" '.event=="pr.skipped" and .reason=="no_new_commits" and .basis=="position"')"

# ===========================================================================
printf '\n== a dry run never reaches the error comment at all ==\n'
# post_comment is only called for a THUMBS_DOWN, and under --dry-run request_review
# returns success before it can fail, so the failure comment is unreachable. Asserted
# rather than left implied, because the obvious reading of the code says otherwise.
d="$(scenario dry_comment_unreachable)"
page "${d}" first "" 991
pr_fresh "${d}" pr-991.json "${MENTION}"
printf 'HTTP 403: Resource not accessible by integration\n' >"${d}/fail-request"
run "${d}" --dry-run
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "nothing was posted" 0 "$(calls "${d}/calls.log" comment)"
assert_eq "and no comment event was logged either" 0 \
    "$(events "${d}/out.log" '.event=="comment.posted"')"
assert_eq "the mention was acknowledged as a would-be request" 1 \
    "$(events "${d}/out.log" '.event=="review.requested" and .dry_run==true')"

# ===========================================================================
printf '\n== a 429 on a read is retried, unlike a settled refusal ==\n'
d="$(scenario retry_429)"
page "${d}" first "" 995
pr_fresh "${d}" pr-995.json
printf 'HTTP 429: rate limit exceeded\n' >"${d}/fail-pr"
RUN_ENV=(MAX_CONSECUTIVE_READ_FAILURES=1)
run "${d}" --verbose
assert_eq "exit status is 1" 1 "${rc}"
# Three attempts for the one PR, where a NOT_FOUND gets exactly one.
assert_eq "the read was retried to the attempt limit" 3 "$(calls "${d}/calls.log" pr)"
assert_eq "and each attempt was visible under --verbose" 3 \
    "$(events "${d}/out.log" '.event=="gh.error"')"

# ===========================================================================
printf '\n== without timeout(1) the run warns rather than pretending ==\n'
# gh has no request timeout of its own, so an unwrapped call can stall the run
# until the platform kills it, which costs the lock as well as the cycle.
d="$(scenario no_timeout)"
page "${d}" first "" 997
pr_fresh "${d}" pr-997.json
: >"${d}/calls.log"
rc=0
# A symlink farm of everything on the suite's own tool PATH, minus timeout and
# gtimeout. Built by mirroring the directories rather than by resolving each tool
# by name, so it cannot be defeated by a shell that shadows one of them.
notimeout="${d}/notimeout"
mkdir -p "${notimeout}"
while IFS= read -r -d ':' toold || [[ -n "${toold}" ]]; do
    [[ -d "${toold}" ]] || continue
    for f in "${toold}"/*; do
        [[ -x "${f}" && ! -d "${f}" ]] || continue
        case "${f##*/}" in
            timeout | gtimeout) continue ;;
        esac
        [[ -e "${notimeout}/${f##*/}" ]] || ln -s "${f}" "${notimeout}/${f##*/}"
    done
done <<<"${TOOL_PATH}:"
env -i PATH="${d}/bin:${notimeout}" HOME="${d}" FAKE_DIR="${d}" \
    "${BASE_ENV[@]}" \
    GH_TOKEN=stub-token STATE_DIR="${d}/state" SLEEP_BETWEEN_MUTATIONS=0 LOG_FORMAT=json \
    "${BASH_BIN}" "${BOT}" --repo XRPLF/rippled >"${d}/out.log" 2>&1 || rc=$?
LAST_LOG="${d}/out.log"
assert_eq "exit status is 0, it still runs" 0 "${rc}"
assert_eq "it warned that gh calls are unbounded" 1 \
    "$(events "${d}/out.log" '.event=="run.no_gh_timeout" and .severity=="WARNING"')"
assert_eq "and the work still got done" 1 "$(calls "${d}/calls.log" request)"

# ===========================================================================
printf '\n== --pr acts on a PR off the default branch, and says so ==\n'
# Gating --pr on the base branch made the flag a silent no-op for any PR on a
# release branch, and then blamed a --base the operator never passed.
d="$(scenario pr_other_base)"
jq -n '{data:{repository:{defaultBranchRef:{name:"main"},
    pullRequests:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{number:7}]}}}}' \
    >"${d}/page-first.json"
pr_fresh "${d}" pr-7.json '{"baseRefName":"release/2.6"}'
run "${d}" --pr 7
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the request went out" 1 "$(calls "${d}/calls.log" request)"
assert_eq "it said the gate was bypassed, at INFO" 1 \
    "$(events "${d}/out.log" '.event=="pr.base_gate_bypassed" and .severity=="INFO"')"
assert_eq "and it did not blame --base" 0 \
    "$(events "${d}/out.log" '.event=="repo.no_matching_base"')"

# ===========================================================================
printf '\n== an error that merely contains "already" is still a failure ==\n'
# `grep -qi already` over the whole error text reported any such failure as a
# duplicate reaction and returned success, marking the mention answered forever.
d="$(scenario react_already)"
page "${d}" first "" 999
pr_fresh "${d}" pr-999.json "${MENTION}"
printf 'HTTP 403: the repository has already been archived\n' >"${d}/fail-react"
run "${d}"
assert_eq "the failure was reported, not swallowed" 1 \
    "$(events "${d}/out.log" '.event=="reaction.failed"')"
assert_eq "it was not called a duplicate" 0 \
    "$(events "${d}/out.log" '.event=="reaction.exists"')"
assert_eq "and the run says so" 1 "${rc}"

printf '\n== a genuine duplicate reaction is still not escalated ==\n'
d="$(scenario react_dup)"
page "${d}" first "" 998
pr_fresh "${d}" pr-998.json "${MENTION}"
printf 'Reaction already exists for this subject\n' >"${d}/fail-react"
run "${d}" --verbose
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "it was treated as already present" 1 \
    "$(events "${d}/out.log" '.event=="reaction.exists"')"
assert_eq "and not reported as a failure" 0 \
    "$(events "${d}/out.log" '.event=="reaction.failed"')"

# ===========================================================================
printf '\n== reactions are capped per run, like requests ==\n'
# MAX_REQUESTS_PER_RUN bounds review requests and nothing else, so without its own cap
# the mention loop writes one mutation and one sleep per unhandled mention. A comment
# window of 100 plus 100 threads of 20 is up to 2100 on a single PR, which no task
# timeout allows. The remainder is left unreacted, which is the state the next run
# already treats as outstanding.
d="$(scenario mention_cap)"
page "${d}" first "" 60
pr_fresh "${d}" pr-60.json '{"comments":{"nodes":[
    {"id":"IC_A","createdAt":"2026-08-20T10:00:00Z","body":"@xrplf-bot please",
     "author":{"login":"alice"},"reactionGroups":[]},
    {"id":"IC_B","createdAt":"2026-08-20T11:00:00Z","body":"@xrplf-bot again",
     "author":{"login":"bob"},"reactionGroups":[]},
    {"id":"IC_C","createdAt":"2026-08-20T12:00:00Z","body":"@xrplf-bot once more",
     "author":{"login":"carol"},"reactionGroups":[]}]}}'
RUN_ENV=(MAX_MENTION_WRITES_PER_RUN=2)
run "${d}"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "only the capped number of reactions was written" 2 "$(calls "${d}/calls.log" react)"
assert_eq "and it said why it stopped" 1 \
    "$(events "${d}/out.log" '.event=="mention.writes_halted" and .reason=="write_cap"')"
assert_eq "run.done reports the count" 1 \
    "$(events "${d}/out.log" '.event=="run.done" and .mention_writes==2')"

printf '\n== and uncapped, every mention on the PR is answered ==\n'
d="$(scenario mention_uncapped)"
page "${d}" first "" 60
pr_fresh "${d}" pr-60.json '{"comments":{"nodes":[
    {"id":"IC_A","createdAt":"2026-08-20T10:00:00Z","body":"@xrplf-bot please",
     "author":{"login":"alice"},"reactionGroups":[]},
    {"id":"IC_B","createdAt":"2026-08-20T11:00:00Z","body":"@xrplf-bot again",
     "author":{"login":"bob"},"reactionGroups":[]}]}}'
run "${d}"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "both were answered" 2 "$(calls "${d}/calls.log" react)"
assert_eq "and nothing was halted" 0 "$(events "${d}/out.log" '.event=="mention.writes_halted"')"

# ===========================================================================
printf '\n== a repo-wide reaction failure stops after two, not once per mention ==\n'
# The breaker requests already had. A token that has lost Issues: write fails every
# reaction identically, so walking the rest costs one mutation and one second each and
# tells nobody anything new.
d="$(scenario mention_breaker)"
page "${d}" first "" 61
pr_fresh "${d}" pr-61.json '{"comments":{"nodes":[
    {"id":"IC_A","createdAt":"2026-08-20T10:00:00Z","body":"@xrplf-bot please",
     "author":{"login":"alice"},"reactionGroups":[]},
    {"id":"IC_B","createdAt":"2026-08-20T11:00:00Z","body":"@xrplf-bot again",
     "author":{"login":"bob"},"reactionGroups":[]},
    {"id":"IC_C","createdAt":"2026-08-20T12:00:00Z","body":"@xrplf-bot once more",
     "author":{"login":"carol"},"reactionGroups":[]},
    {"id":"IC_D","createdAt":"2026-08-20T13:00:00Z","body":"@xrplf-bot and again",
     "author":{"login":"dave"},"reactionGroups":[]}]}}'
printf 'HTTP 403: Resource not accessible by personal access token\n' >"${d}/fail-react"
run "${d}"
assert_eq "exit status is 1" 1 "${rc}"
assert_eq "it stopped after the threshold" 2 "$(calls "${d}/calls.log" react)"
assert_eq "the failure was an ERROR, matching its class" 2 \
    "$(events "${d}/out.log" '.event=="reaction.failed" and .severity=="ERROR" and .failure_class=="permanent"')"
assert_eq "and it said the breaker fired" 1 \
    "$(events "${d}/out.log" '.event=="mention.writes_halted" and .reason=="permanent_failures"')"

# ===========================================================================
printf '\n== a transient read failure does not fail the run ==\n'
# The documented contract: exit 1 means the run did less than it was asked to, and one
# 502 out of hundreds of reads is not that - the next tick retries it. A whole
# execution going red on a blip is the alert fatigue the design says it avoids.
d="$(scenario read_transient)"
page "${d}" first "" 70
pr_fresh "${d}" pr-70.json
printf 'HTTP 502: Bad Gateway\n' >"${d}/fail-pr"
RUN_ENV=(GH_MAX_ATTEMPTS=1)
run "${d}"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "it was reported as transient, at WARNING" 1 \
    "$(events "${d}/out.log" '.event=="pr.read_failed" and .severity=="WARNING" and .failure_class=="transient"')"
assert_eq "and counted as one to retry" 1 \
    "$(events "${d}/out.log" '.event=="run.done" and .transient_failures==1')"

printf '\n== unless the operator asked to know about transients ==\n'
d="$(scenario read_transient_strict)"
page "${d}" first "" 70
pr_fresh "${d}" pr-70.json
printf 'HTTP 502: Bad Gateway\n' >"${d}/fail-pr"
RUN_ENV=(GH_MAX_ATTEMPTS=1 TRANSIENT_FAILURES_ARE_ERRORS=true)
run "${d}"
assert_eq "exit status is 1" 1 "${rc}"

printf '\n== a permanent read failure does fail the run ==\n'
d="$(scenario read_permanent)"
page "${d}" first "" 70
pr_fresh "${d}" pr-70.json
printf 'HTTP 403: Forbidden\n' >"${d}/fail-pr"
RUN_ENV=(GH_MAX_ATTEMPTS=1)
run "${d}"
assert_eq "exit status is 1" 1 "${rc}"
assert_eq "reported at ERROR as permanent" 1 \
    "$(events "${d}/out.log" '.event=="pr.read_failed" and .severity=="ERROR" and .failure_class=="permanent"')"

printf '\n== and an abandoned sweep fails the run whatever the class ==\n'
# Three transient failures in a row still means the run gave up on work it was asked
# to do, which somebody should see even though every cause was a blip.
d="$(scenario read_halted)"
page "${d}" first "" 70 71 72 73
pr_fresh "${d}" pr-any.json
printf 'HTTP 502: Bad Gateway\n' >"${d}/fail-pr"
RUN_ENV=(GH_MAX_ATTEMPTS=1 MAX_CONSECUTIVE_READ_FAILURES=3)
run "${d}"
assert_eq "exit status is 1" 1 "${rc}"
assert_eq "the breaker reported the remaining count too" 1 \
    "$(events "${d}/out.log" '.event=="reads.halted" and .reason=="read_failures" and .remaining==1')"
assert_eq "and run.done names the read failures, not the cap" 1 \
    "$(events "${d}/out.log" '.event=="run.done" and .stop_reason=="read_failures"')"

# ===========================================================================
printf '\n== a token the API will not name an account for is a clean fatal ==\n'
# The most likely real failure of all, and neither arm was reachable before.
d="$(scenario viewer_empty)"
page "${d}" first "" 80
pr_fresh "${d}" pr-80.json
touch "${d}/empty-viewer"
run "${d}"
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "it says no login came back" 1 \
    "$(events "${d}/out.log" '.event=="run.fatal" and .reason=="viewer_unknown"')"
assert_eq "and no PR was touched" 0 "$(calls "${d}/calls.log" pr)"

printf '\n== an identity call that fails outright is also fatal, with the class ==\n'
d="$(scenario viewer_failed)"
page "${d}" first "" 80
pr_fresh "${d}" pr-80.json
printf 'HTTP 401: Bad credentials\n' >"${d}/fail-viewer"
RUN_ENV=(GH_MAX_ATTEMPTS=1)
run "${d}"
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "it reports the failure class" 1 \
    "$(events "${d}/out.log" '.event=="run.fatal" and .reason=="viewer_unknown" and .failure_class=="permanent"')"

# ===========================================================================
printf '\n== the flags with no other coverage ==\n'
d="$(scenario cli_flags)"
page "${d}" first "" 90
pr_fresh "${d}" pr-90.json
run "${d}" --mention-age 30 --ignore-outdated
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the run started" 1 "$(events "${d}/out.log" '.event=="run.start"')"
assert_eq "and the mention window moved with --mention-age" 1 \
    "$(events "${d}/out.log" '.event=="run.start" and (.mention_since|type)=="string"')"

printf '\n== there are no positional arguments, so a bare one is refused ==\n'
# The repository has one spelling, --repo, so a bare argument is refused rather than
# guessed at, and the message names the flag to use instead. '--' goes the same way:
# with nothing positional to separate, it is just an unknown option.
for bad_arg in XRPLF/rippled --; do
    d="$(scenario "cli_positional_$(printf '%s' "${bad_arg}" | tr -cd '[:alnum:]')")"
    page "${d}" first "" 91
    pr_fresh "${d}" pr-91.json
    : >"${d}/calls.log"
    rc=0
    env -i PATH="${d}/bin:${TOOL_PATH}:/usr/bin:/bin" HOME="${d}" FAKE_DIR="${d}" \
        "${BASE_ENV[@]}" \
        GH_TOKEN=stub-token STATE_DIR="${d}/state" SLEEP_BETWEEN_MUTATIONS=0 \
        LOG_FORMAT=json \
        "${BASH_BIN}" "${BOT}" "${bad_arg}" >"${d}/out.log" 2>&1 || rc=$?
    LAST_LOG="${d}/out.log"
    assert_eq "'${bad_arg}': exit status is 2" 2 "${rc}"
    assert_eq "'${bad_arg}': refused as a bad option, naming it" 1 \
        "$(events "${d}/out.log" ".event==\"run.fatal\" and .reason==\"bad_option\" and (.message|test(\"${bad_arg}\"))")"
    assert_eq "'${bad_arg}': nothing was queried" 0 "$(calls "${d}/calls.log" list)"
done

printf '\n== a run with no repository at all is a findable event ==\n'
# Every other exit-2 path emits run.fatal. A bare help dump carries no severity, no
# event and no time, so the runbook filters and the ERROR metric both miss it.
d="$(scenario cli_no_repo)"
rc=0
env -i PATH="${d}/bin:${TOOL_PATH}:/usr/bin:/bin" HOME="${d}" FAKE_DIR="${d}" \
    "${BASE_ENV[@]}" \
    GH_TOKEN=stub-token STATE_DIR="${d}/state" LOG_FORMAT=json \
    "${BASH_BIN}" "${BOT}" >"${d}/out.log" 2>&1 || rc=$?
LAST_LOG="${d}/out.log"
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "it named the reason" 1 \
    "$(events "$(json_only "${d}/out.log")" '.event=="run.fatal" and .reason=="no_repos"')"

summary

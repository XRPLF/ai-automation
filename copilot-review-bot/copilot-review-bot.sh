#!/usr/bin/env bash
#
# copilot-review-bot.sh - poll GitHub pull requests and request (or re-request)
# a GitHub Copilot code review when one is due.
#
# One process watches one repository. Every run is a fresh poll of the current state
# of it. There is no webhook receiver and no inbound port, so it runs anywhere with
# outbound HTTPS: a Cloud Run job, a cron entry, a systemd timer.
#
# The decision rules, the prerequisites and the token permissions live in README.md
# in this directory. usage() prints the block below verbatim as --help, so that one
# is both the text and its documentation.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   copilot-review-bot.sh [options]
#
#   -r, --repo owner/name     The one repository to monitor. Required, here or
#                             in ${REPO}. There are no positional arguments.
#       --base BRANCH         Base branch to gate automatic requests on.
#                             Default: the repo's own default branch.
#       --pr N                Only look at this PR number (debugging).
#       --state DIR           Root under which the lock and the head-commit
#                             markers live. Both are kept in an <owner>/<name>
#                             subdirectory of it, so any number of single-repo
#                             processes can share one root. A gs://bucket URL,
#                             with an optional /prefix, keeps them in Cloud
#                             Storage, which is what Cloud Run needs: its local
#                             disk does not survive an execution.
#                             Env: STATE_DIR.
#       --reviewer NAME       Who to request the review from, as a GitHub login.
#                             Default: copilot-pull-request-reviewer[bot], the
#                             Copilot reviewer. A bot keeps the '[bot]' suffix,
#                             a person is bare (monalisa) and a team is
#                             owner/slug (myorg/team-name). Env: REVIEWER.
#       --mention-handle NAME Mention handle without '@'. Default: xrplf-bot.
#       --mention-age DAYS    Ignore mention comments older than this.
#                             Default: 7. Keeps a first run from replying to
#                             years of history.
#       --max-requests N      Stop the run after N review requests. Default:
#                             25. Guards against a storm on day one and
#                             against GitHub's secondary rate limits. The
#                             remaining PRs are left to the next run.
#       --ignore-outdated     Treat outdated (code-has-since-changed) Copilot
#                             threads as if they were resolved.
#       --log-format FMT      json (default: one JSON object per line, which
#                             Cloud Logging parses into jsonPayload) or text
#                             (logfmt, for reading in a terminal).
#   -n, --dry-run             Report what would happen; change nothing on GitHub
#                             and take no lock, local or gs://.
#   -v, --verbose             Log every PR, including the skipped ones.
#       --explain FILE        Debug: run the decision logic over a saved
#                             pullRequest JSON object and print the result.
#       --version             Print the version and exit.
#   -h, --help                This text.
#
# Exit status: 0 nothing failed, 1 something that should have happened did not,
# 2 fatal/usage, 143 or 130 killed by a signal.
#
# A run with nothing to do exits 0: every pull request already up to date is the
# normal steady state, not a warning.
#
# A transient failure on one pull request also exits 0, because the next run
# retries it. Set TRANSIENT_FAILURES_ARE_ERRORS=true if your alerting wants to
# know. Exiting 1 covers a permanent error on a PR, a repository that could not be
# listed at all, and a sweep abandoned after repeated read failures - the cases
# where waiting for the next run is not the whole remedy.
# --- end usage ---
#
# The jq programs below (JQ_LIB, JQ_DECIDE, ...) are single-quoted on
# purpose, so the shell leaves them untouched; only jq's own $vars, passed
# in via --argjson/--arg, are meant to expand.
# shellcheck disable=SC2016
#
# -E matters as much as -e: without errtrace the ERR trap is not inherited into
# function bodies, and almost every command here runs inside one, so an
# unexpected failure would end the run with no terminal event at all.
set -Eeuo pipefail

# gh writes its HTTP trace to stderr when this is set, and still exits 0. Every read
# here captures gh's output and parses it as JSON, so an inherited value would corrupt
# every query. Unset, not honored: the bot has its own --verbose.
unset GH_DEBUG

# Checked here, before anything else, and written out by hand rather than through
# emit(). 4.4 is the floor: earlier releases treat "${empty_array[@]}" as an unbound
# variable under `set -u`, which this script relies on throughout, and they have no
# associative arrays at all. macOS still ships 3.2 as /bin/bash, so this fires there
# unless a newer bash is first on PATH. Everything below this point may use bash 4.4
# syntax; this block may not, or the shell it is meant to catch dies on the check
# itself. It carries a time and goes to stdout like every other event, because the
# one-object-per-line contract has to hold on the very first line too.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] ||
    { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    printf '{"time":"%s","severity":"ERROR","event":"run.fatal","reason":"bash_too_old","message":"bash 4.4 or newer is required; this is %s at %s. On macOS: brew install bash, then run the script with that bash."}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo -)" \
        "${BASH_VERSION:-unknown}" "${BASH:-unknown}"
    exit 2
fi

VERSION="1.4.0"

# ---------------------------------------------------------------------------
# Configuration (all overridable by environment)
# ---------------------------------------------------------------------------

# The login Copilot's review bot reviews under, lowercased. Compared
# case-insensitively against review authors, requested reviewers and thread openers.
# This is how *detection* works - "has Copilot reviewed this, and is that review
# stale" - and it is deliberately a name test rather than an id test, because
# GitHub's node id for an account is GitHub's to change while the login is the
# stable handle. Requesting a review is the other direction entirely, and uses
# ${REVIEWER}.
#
# One entry, because one is what GitHub reports: GraphQL returns this login on a Bot
# node, with no '[bot]' suffix. 'copilot' and 'github-copilot' used to sit beside it
# as insurance against a rename, but neither is a real account - both 404 on
# api.github.com/users - so they could only ever have matched if GitHub renamed the
# bot to exactly one of those two strings. A rename means editing this list either
# way, so the guesses bought nothing and made the list look like observed fact.
#
# Comma separated, so it needs no shell quoting of brackets in an env var or a
# --set-env-vars value. It is turned into the JSON array jq wants at the one point
# jq is handed it, further down.
COPILOT_LOGINS="${COPILOT_LOGINS:-copilot-pull-request-reviewer}"

# Who to request the review from, as the login the requestReviewsByLogin mutation
# wants. Still a login and not a node id, for the same reason COPILOT_LOGINS is:
# GitHub owns the id and the login is the stable handle.
#
# The default is Copilot's reviewer bot with the '[bot]' suffix GitHub writes bot
# logins with, and that suffix is load bearing - see REVIEWER_FIELD below, which uses
# it to decide which of the mutation's three lists the value belongs in. It is the one
# spelling difference from COPILOT_LOGINS, which holds what GraphQL *reports* on a Bot
# node, and that has no suffix.
#
# Overridable for a person or a team. A value containing '@' cannot travel through
# deploy-job.sh, which joins the job environment with '^@^' - see
# deploy/rate-budget.sh, which refuses an '@' in any jobs.json string. Nothing per job
# sets this, and the '@' forms are refused below anyway, so that costs nothing.
REVIEWER="${REVIEWER:-copilot-pull-request-reviewer[bot]}"

# Which of requestReviewsByLogin's three lists carries ${REVIEWER}. Settled once, from
# the setting, by the case statement in the validation section further down.
REVIEWER_FIELD=""

# Local directory, or gs://bucket with an optional /prefix, and the root rather than
# the leaf: the repository being watched is appended to it as <owner>/<name>, so any
# number of single-repo processes can be pointed at one root without colliding. The
# prefix is optional and production omits it, so parse_state_dir has to join without
# leaving a '//'. See the state section further down. ${HOME}/.local/state is the XDG fallback for XDG_STATE_HOME,
# which is unset on a stock macOS or Debian shell; /tmp only when HOME is unset too.
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/copilot-review-bot}"

# Defaults to ${STATE_DIR}/<owner>/<name>/lock. Only used by a local state
# directory: a gs:// one locks with an object in the bucket instead.
LOCK_FILE="${LOCK_FILE:-}"

MENTION_HANDLE="${MENTION_HANDLE:-xrplf-bot}"
MENTION_MAX_AGE_DAYS="${MENTION_MAX_AGE_DAYS:-7}"
MAX_REQUESTS_PER_RUN="${MAX_REQUESTS_PER_RUN:-25}"

# Reactions and error comments the run may write, in total. MAX_REQUESTS_PER_RUN
# bounds review requests and nothing else, and the mention loop writes one mutation
# per unhandled mention with no reference to it. A comment window of 100 plus 100
# threads of 20 is up to 2100 mentions on one pull request, each one a mutation and a
# SLEEP_BETWEEN_MUTATIONS, which is more than any task timeout allows. The remainder
# is left unreacted, which is exactly the state the next run treats as outstanding.
MAX_MENTION_WRITES_PER_RUN="${MAX_MENTION_WRITES_PER_RUN:-50}"

IGNORE_OUTDATED="${IGNORE_OUTDATED:-false}"

# How long a head-commit marker is kept. It only guards the window between
# filing a request and GitHub reporting it as pending, so anything older is
# dead weight.
MARKER_MAX_AGE_DAYS="${MARKER_MAX_AGE_DAYS:-90}"

# How long a lock may be held before another run treats it as abandoned and
# breaks it. Has to exceed the longest healthy run, and should not exceed it by
# much: a run killed by its platform (a Cloud Run task timeout, say) holds the
# lock for the remainder of this window, and every tick in that window is lost.
LOCK_TTL_MINUTES="${LOCK_TTL_MINUTES:-30}"

# What to do when the branch was force-pushed after a Copilot review and no
# commit on it was authored after that review - a restack or an amend, with
# nothing in the metadata to tell them apart. false waits for a commit that is
# demonstrably new work (anyone can still ask with an @mention); true treats any
# rewrite as new work, which re-reviews on every rebase.
REWRITE_TRIGGERS_REVIEW="${REWRITE_TRIGGERS_REVIEW:-false}"
SLEEP_BETWEEN_MUTATIONS="${SLEEP_BETWEEN_MUTATIONS:-1}"

# Heartbeat interval, in PRs, for non-verbose runs. 0 disables it. Verbose runs
# log every PR anyway and skip this.
PROGRESS_EVERY="${PROGRESS_EVERY:-25}"

# How many open PRs this repository is expected to have. Nothing here enforces it: the run
# reads however many there are. It exists so a run can say when the deployment's own
# assumption has gone stale, because that assumption is what deploy/rate-budget.sh charges
# the GraphQL quota at, and a repository that has grown past it spends more than the fleet
# was budgeted for. Nothing else compares the two - the declared figure lives in jobs.json,
# which the bot never reads, and the true count is only known here.
#
# Empty disables the check, which is what a local run gets. 0 is a real value meaning "warn
# about any open PR at all", so it cannot be the "unset" marker.
EXPECTED_OPEN_PRS="${EXPECTED_OPEN_PRS:-}"

# json (one object per line, for Cloud Logging and friends) or text (logfmt).
LOG_FORMAT="${LOG_FORMAT:-json}"

# Consecutive transient request failures before this run stops making requests
# altogether and leaves the rest to the next one. If GitHub is having a bad
# minute there is no point walking the remaining PRs one 502 at a time.
MAX_CONSECUTIVE_TRANSIENT="${MAX_CONSECUTIVE_TRANSIENT:-3}"

# The same guard for permanent failures. A permanent error on a review request is
# almost always repo-wide - the account lost Triage, Copilot has no seat, or
# ${REVIEWER} no longer resolves - so after a couple of them there is nothing to learn
# from trying the rest of the PRs one refusal at a time. 2 is enough to tell a
# repo-wide fact from a per-PR one.
MAX_CONSECUTIVE_PERMANENT="${MAX_CONSECUTIVE_PERMANENT:-2}"

# Consecutive read failures before the sweep is abandoned. Without this a
# degraded GitHub costs three attempts and nine seconds of sleeping per PR,
# which on a busy repo exceeds any sane task timeout.
MAX_CONSECUTIVE_READ_FAILURES="${MAX_CONSECUTIVE_READ_FAILURES:-3}"

# Wall-clock budget for the whole run, in seconds. Checked between PRs so the
# run stops on its own terms rather than being killed by the platform, which
# would cost the lock as well as the cycle. Keep it below the task timeout. 0
# disables it.
RUN_DEADLINE_SECONDS="${RUN_DEADLINE_SECONDS:-900}"

# Timeout for a single gh invocation. gh has no request timeout of its own, so a
# connected socket that stops sending bytes would otherwise stall the run until
# the platform kills it.
GH_TIMEOUT="${GH_TIMEOUT:-60}"

# Attempts per read, and the linear backoff base in seconds: attempt 1 waits
# 1x, attempt 2 waits 2x. Tunable because the resulting cost is what
# MAX_CONSECUTIVE_READ_FAILURES exists to bound, and because the test suites can
# then exercise the retry path without paying for it in wall clock.
GH_MAX_ATTEMPTS="${GH_MAX_ATTEMPTS:-3}"
GH_RETRY_BASE_SECONDS="${GH_RETRY_BASE_SECONDS:-3}"

# Per-call timeouts for Cloud Storage and for the metadata server. Both are
# lowered to CLEANUP_HTTP_TIMEOUT once the exit trap is running, because a
# platform that is shutting the run down gives it only a few seconds and the work
# has to fit inside that rather than inside these.
GCS_HTTP_TIMEOUT="${GCS_HTTP_TIMEOUT:-60}"
GCS_TOKEN_TIMEOUT="${GCS_TOKEN_TIMEOUT:-10}"
CLEANUP_HTTP_TIMEOUT="${CLEANUP_HTTP_TIMEOUT:-3}"

# Attempts per Cloud Storage call. Every call the bot makes is idempotent - an
# upload names its object, a delete carries a precondition - so a retry cannot
# duplicate a side effect. Without this a single 503 lost a whole run's markers.
GCS_MAX_ATTEMPTS="${GCS_MAX_ATTEMPTS:-3}"
# The linear backoff base in seconds, applied the same way GH_RETRY_BASE_SECONDS is:
# attempt 1 waits 1x and attempt 2 waits 2x, so the default costs 6s across the three
# attempts above. Tunable for the same reason as its GitHub counterpart - the suites
# exercise the retry path without paying for it in wall clock, since they assert that
# the retry happened and never on how long it waited. 0 retries immediately.
GCS_RETRY_BASE_SECONDS="${GCS_RETRY_BASE_SECONDS:-2}"

# Whether a transient failure should make the run exit non-zero. It is a warning
# by default: the retry is the remedy, and a job that fails every time GitHub
# hiccups trains people to ignore it. Set true if your alerting wants to know.
TRANSIENT_FAILURES_ARE_ERRORS="${TRANSIENT_FAILURES_ARE_ERRORS:-false}"

# The one repository this process watches, from --repo or ${REPO}. Last wins, like
# every other setting here. Main splits it into the two halves below, which is what
# everything downstream wants.
repo=""
owner=""
name=""
base_override=""
only_pr=""
dry_run=false
verbose=false
explain_file=""
exit_status=0
requests_made=0
# Every request the run has tried, successful or not, because the cap is measured
# against attempts: a failing request costs GitHub as much as a successful one.
request_attempts=0
would_request=0
deferrals=0
transients=0
consecutive_transients=0
consecutive_permanents=0
consecutive_read_failures=0
# PRs skipped this repo because they target another branch. All of them means
# --base matches nothing, which is otherwise a silent successful no-op.
other_base_skips=0
# Reactions and error comments written this run, against MAX_MENTION_WRITES_PER_RUN,
# plus the consecutive-permanent counter that stops a repo-wide reaction failure from
# being retried once per mention. Requests have both guards; without these, mentions
# had neither.
mention_writes=0
consecutive_mention_permanents=0
mention_writes_halted=false
mention_cap_announced=false
requests_halted=false
halt_reason=""
cap_announced=false
stop_scanning=false
deadline_hit=false
viewer=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
#   emit <severity> <event> <message> [key=value | key#=rawjson]...
#
# One event per line: a JSON object in json mode, logfmt in text mode. Cloud
# Logging promotes `severity`, `message` and `time` onto the entry and puts the
# rest in jsonPayload; `event`, `repo` and `pr` are also copied into
# logging.googleapis.com/labels so they can be filtered as labels.
#
# A trailing '#' on a key emits the value as raw JSON, so numbers and booleans
# stay typed and Cloud Logging can build metrics on them. Every setting that
# reaches the log that way is validated at startup. `repo` and `pr` come from the
# current context, so call sites do not repeat them. One stream, so events stay in
# order and severity rather than the choice of stream marks a problem.

# Fixed for the whole process so timestamps are UTC and the control-character
# scrub below collates predictably.
export TZ=UTC
export LC_ALL=C

ctx_repo=""
ctx_pr=""

# The log stream, held open separately from stdout. Reads are captured with $( ), so
# an event written to stdout inside one would land in the payload instead of the log,
# and the decision would then be computed from a null document. Writing to this fd
# means an event reaches the log from anywhere, including inside a substitution.
exec {LOG_FD}>&1

log_time() {
    # bash 5 can format this without forking; older shells fall back to date,
    # and preflight tolerates date being missing altogether.
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local now="${EPOCHREALTIME}" secs frac
        secs="${now%%[.,]*}"
        frac="${now#*[.,]}"
        printf '%(%Y-%m-%dT%H:%M:%S)T.%sZ' "${secs}" "${frac:0:3}"
    else
        date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf -- '-'
    fi
}

# RFC 3339, second resolution. Used for stored timestamps, which are compared
# as strings, so the format has to be stable.
timestamp_now() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf -- '-'; }

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//[$'\x01'-$'\x1f']/ }"
    printf '%s' "${s}"
}

emit() { # <severity> <event> <message> [key=value | key#=rawjson]...
    local severity="$1" event="$2" message="$3"
    shift 3
    [[ "${severity}" == DEBUG && "${verbose}" != true ]] && return 0

    local -a pairs=()
    [[ -n "${ctx_repo}" ]] && pairs+=("repo=${ctx_repo}")
    [[ -n "${ctx_pr}" ]] && pairs+=("pr#=${ctx_pr}")
    pairs+=("$@")

    local kv key val out
    if [[ "${LOG_FORMAT}" == text ]]; then
        out="$(log_time) ${severity} ${event}"
        [[ -n "${message}" ]] && out+=" ${message}"
        for kv in "${pairs[@]}"; do
            key="${kv%%=*}"
            val="${kv#*=}"
            # Newlines and tabs would split one event across lines, and a value
            # containing a space or '=' is unparseable as logfmt unless quoted.
            val="${val//$'\n'/ }"
            val="${val//$'\r'/ }"
            val="${val//$'\t'/ }"
            if [[ "${val}" == *[[:space:]=]* || -z "${val}" ]]; then
                val="\"${val//\"/\\\"}\""
            fi
            out+=" ${key%\#}=${val}"
        done
        printf '%s\n' "${out}" >&"${LOG_FD}"
        return 0
    fi

    out="{\"time\":\"$(log_time)\",\"severity\":\"${severity}\""
    out+=",\"event\":\"$(json_escape "${event}")\""
    [[ -n "${message}" ]] && out+=",\"message\":\"$(json_escape "${message}")\""
    for kv in "${pairs[@]}"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        if [[ "${key}" == *\# ]]; then
            [[ -z "${val}" ]] && val=null
            out+=",\"$(json_escape "${key%\#}")\":${val}"
        else
            out+=",\"$(json_escape "${key}")\":\"$(json_escape "${val}")\""
        fi
    done
    # Labels are indexed, so the three things worth filtering on go there too.
    out+=",\"logging.googleapis.com/labels\":{\"event\":\"$(json_escape "${event}")\""
    [[ -n "${ctx_repo}" ]] && out+=",\"repo\":\"$(json_escape "${ctx_repo}")\""
    [[ -n "${ctx_pr}" ]] && out+=",\"pr\":\"$(json_escape "${ctx_pr}")\""
    out+='}'
    printf '%s}\n' "${out}" >&"${LOG_FD}"
}

# A usage error, before there is anything more specific to name. Carries a
# `reason` like every other run.fatal, so a filter on that field misses nothing.
die() {
    emit ERROR run.fatal "$*" reason=bad_option
    exit 2
}
usage() {
    # The range ends on an explicit sentinel, because a sed range stops *on* its
    # matching line and would otherwise drop the last paragraph. -E, because BSD sed
    # has no \? in a basic regular expression.
    sed -n '/^# Usage/,/^# --- end usage ---/p' "$0" |
        sed -E '/^# --- end usage ---$/d; /^# ?-+$/d; s/^# ?//'
    exit "${1:-2}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
# Every option that takes a value checks for it first. Reading "$2" under `set -u`
# without checking dies with a raw bash "unbound variable" and exit 1, which
# collides with the documented meaning of exit 1 (a PR hit a permanent error), so
# alerting could not tell a typo from a real failure.
need_value() { # <option> <remaining-arg-count>
    (($2 >= 2)) || {
        emit ERROR run.fatal "option $1 needs a value" \
            reason=bad_option setting="$1" given=""
        exit 2
    }
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r | --repo)
            need_value "$1" $#
            repo="$2"
            shift 2
            ;;
        --base)
            need_value "$1" $#
            # A value starting with '-' is almost always the next flag, swallowed
            # because the branch name was left out. Unchecked it is accepted as a
            # branch nothing targets, and every PR is then skipped at DEBUG, so
            # the run reports success having done nothing.
            [[ "$2" == -* ]] && die "--base needs a branch name, not '$2'"
            base_override="$2"
            shift 2
            ;;
        --pr)
            need_value "$1" $#
            only_pr="$2"
            shift 2
            ;;
        --state)
            need_value "$1" $#
            STATE_DIR="$2"
            shift 2
            ;;
        --reviewer)
            need_value "$1" $#
            REVIEWER="$2"
            shift 2
            ;;
        --mention-handle)
            need_value "$1" $#
            MENTION_HANDLE="$2"
            shift 2
            ;;
        --mention-age)
            need_value "$1" $#
            MENTION_MAX_AGE_DAYS="$2"
            shift 2
            ;;
        --max-requests)
            need_value "$1" $#
            MAX_REQUESTS_PER_RUN="$2"
            shift 2
            ;;
        --ignore-outdated)
            IGNORE_OUTDATED=true
            shift
            ;;
        --log-format)
            need_value "$1" $#
            LOG_FORMAT="$2"
            shift 2
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
            need_value "$1" $#
            explain_file="$2"
            shift 2
            ;;
        --version)
            echo "copilot-review-bot.sh ${VERSION}"
            exit 0
            ;;
        -h | --help) usage 0 ;;
        -*) die "unknown option: $1" ;;
        # There are no positional arguments: one spelling per setting, so the
        # repository is named by --repo or ${REPO} and nothing else. '--' therefore has
        # nothing to separate, and lands on the arm above as an unknown option.
        *) die "unexpected argument: $1 (name the repository with --repo owner/name)" ;;
    esac
done

case "${LOG_FORMAT}" in
    json | text) ;;
    *)
        bad_format="${LOG_FORMAT}"
        LOG_FORMAT=json
        emit ERROR run.fatal \
            "unknown log format '${bad_format}'; expected json or text" \
            reason=bad_log_format given="${bad_format}"
        exit 2
        ;;
esac

# Settings that reach the log as raw JSON, or arithmetic, have to be validated
# before either happens: an unchecked value would produce a malformed log line
# instead of a clear complaint.
# One shape for all four, so the event, the reason code and the attributes cannot
# drift between them. The wrappers stay, because the call sites below read better
# naming the kind of value than the pattern that matches it.
require_match() { # <name> <value> <regex> <what-it-must-be>
    [[ "$2" =~ $3 ]] && return 0
    emit ERROR run.fatal "${1} must be ${4}, not '${2}'" \
        reason=bad_option setting="${1}" given="${2}"
    exit 2
}

require_integer() { # <name> <value>
    require_match "$1" "$2" '^[0-9]+$' "a non-negative integer"
}

require_number() { # <name> <value>
    require_match "$1" "$2" '^[0-9]+([.][0-9]+)?$' "a non-negative number"
}

require_boolean() { # <name> <value>
    require_match "$1" "$2" '^(true|false)$' "true or false"
}

# A GitHub login is letters, digits and hyphens. The handle is interpolated into a
# jq regex, so anything else either silently matches nothing (a leading '@' turns
# the pattern into '@@name') or aborts the run outright (an unbalanced paren is a
# jq regex error). Restricting it to a legal login makes both impossible and
# removes the need to escape it downstream.
require_handle() { # <name> <value>
    require_match "$1" "$2" '^[A-Za-z0-9][A-Za-z0-9-]*$' \
        "a GitHub login with no leading '@' (letters, digits and hyphens only)"
}

# True when <login> is one of the comma separated COPILOT_LOGINS. The comparison is
# is_copilot's: case insensitive, with blanks around a separator ignored and empty
# entries dropped. Pure shell rather than jq, so the answer is available while options
# are still being validated, which is before require_binaries has run.
names_copilot() { # <login>
    local want="${1,,}" entry
    local -a entries=()
    IFS=',' read -ra entries <<<"${COPILOT_LOGINS}"
    for entry in "${entries[@]}"; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -n "${entry}" && "${entry,,}" == "${want}" ]] && return 0
    done
    return 1
}

require_integer MAX_REQUESTS_PER_RUN "${MAX_REQUESTS_PER_RUN}"
require_integer MAX_MENTION_WRITES_PER_RUN "${MAX_MENTION_WRITES_PER_RUN}"
require_integer MENTION_MAX_AGE_DAYS "${MENTION_MAX_AGE_DAYS}"
require_integer MARKER_MAX_AGE_DAYS "${MARKER_MAX_AGE_DAYS}"
require_integer LOCK_TTL_MINUTES "${LOCK_TTL_MINUTES}"
require_integer PROGRESS_EVERY "${PROGRESS_EVERY}"
# Only when set, because empty is how the check is switched off, and it reaches the log as a
# raw JSON number when the warning fires.
[[ -n "${EXPECTED_OPEN_PRS}" ]] && require_integer EXPECTED_OPEN_PRS "${EXPECTED_OPEN_PRS}"
require_integer MAX_CONSECUTIVE_TRANSIENT "${MAX_CONSECUTIVE_TRANSIENT}"
require_integer MAX_CONSECUTIVE_PERMANENT "${MAX_CONSECUTIVE_PERMANENT}"
require_integer MAX_CONSECUTIVE_READ_FAILURES "${MAX_CONSECUTIVE_READ_FAILURES}"
require_integer RUN_DEADLINE_SECONDS "${RUN_DEADLINE_SECONDS}"
require_integer GH_TIMEOUT "${GH_TIMEOUT}"
require_integer GCS_HTTP_TIMEOUT "${GCS_HTTP_TIMEOUT}"
require_integer GCS_TOKEN_TIMEOUT "${GCS_TOKEN_TIMEOUT}"
require_integer CLEANUP_HTTP_TIMEOUT "${CLEANUP_HTTP_TIMEOUT}"
require_integer GCS_MAX_ATTEMPTS "${GCS_MAX_ATTEMPTS}"
require_integer GCS_RETRY_BASE_SECONDS "${GCS_RETRY_BASE_SECONDS}"
require_integer GH_RETRY_BASE_SECONDS "${GH_RETRY_BASE_SECONDS}"
require_integer GH_MAX_ATTEMPTS "${GH_MAX_ATTEMPTS}"
require_number SLEEP_BETWEEN_MUTATIONS "${SLEEP_BETWEEN_MUTATIONS}"
require_boolean IGNORE_OUTDATED "${IGNORE_OUTDATED}"
require_boolean REWRITE_TRIGGERS_REVIEW "${REWRITE_TRIGGERS_REVIEW}"
require_boolean TRANSIENT_FAILURES_ARE_ERRORS "${TRANSIENT_FAILURES_ARE_ERRORS}"
require_handle MENTION_HANDLE "${MENTION_HANDLE}"
# requestReviewsByLogin takes three separate lists - userLogins, botLogins and
# teamSlugs - and the mutation itself does not infer which one a login belongs in: the
# caller has to choose the field. So the choice is settled here, from the shape of the
# value, once per run rather than once per request, and a value that fits none of the
# three is refused before any PR is touched. The rules are gh's own, from
# partitionReviewersByType, because gh made this call until the change described in
# "Asking Copilot, by name" in README.md, so a value that worked then works now.
case "${REVIEWER}" in
    "")
        # Empty would otherwise reach GitHub as an empty list, which requests nobody
        # and still reports success, once per due PR, forever.
        emit ERROR run.fatal "REVIEWER (--reviewer) must not be empty" \
            reason=invalid_reviewer
        exit 2
        ;;
    @*)
        # '@copilot' was gh's alias for the Copilot reviewer and the old default here.
        # The mutation has no notion of it. Refused rather than rewritten, so the
        # setting, the log and the wire all stay the same string.
        #
        # What to write instead depends on which '@' value this is. Only the alias
        # resolves to Copilot; anything else is an ordinary login somebody prefixed out
        # of habit, and telling them to write Copilot's login would be wrong twice.
        if [[ "${REVIEWER,,}" == @copilot ]]; then
            reviewer_fix="write 'copilot-pull-request-reviewer[bot]' for Copilot"
        else
            reviewer_fix="write '${REVIEWER#@}'"
        fi
        emit ERROR run.fatal \
            "REVIEWER (--reviewer) is a login, not gh's '@' alias: ${reviewer_fix}, not '${REVIEWER}'" \
            reason=invalid_reviewer given="${REVIEWER}"
        exit 2
        ;;
    # A '/' can only be a team, and the mutation wants it as owner/slug.
    */*) REVIEWER_FIELD=teamSlugs ;;
    # Quoted, so the brackets are a literal suffix and not a character class. This is
    # how GitHub spells a bot login, and the mutation requires the suffix.
    *'[bot]') REVIEWER_FIELD=botLogins ;;
    *)
        # A Copilot login spelled without the suffix reaches this arm, and userLogins is
        # where GitHub refuses it: once per due PR, until MAX_CONSECUTIVE_PERMANENT
        # halts the run. That is the per-PR failure this whole path exists to avoid, so
        # it is refused here instead, naming the suffix rather than the field.
        if names_copilot "${REVIEWER}"; then
            emit ERROR run.fatal \
                "REVIEWER (--reviewer) is '${REVIEWER}', which COPILOT_LOGINS names as Copilot, but the mutation needs the bot suffix: write '${REVIEWER}[bot]'" \
                reason=invalid_reviewer given="${REVIEWER}" setting=REVIEWER
            exit 2
        fi
        REVIEWER_FIELD=userLogins
        ;;
esac
# --pr reaches the log as a raw JSON number, so a non-numeric value would emit a
# line no JSON parser accepts, losing the severity and labels of the one event
# that reports the failure.
[[ -n "${only_pr}" ]] && require_integer --pr "${only_pr}"

# ---------------------------------------------------------------------------
# jq programs
# ---------------------------------------------------------------------------
# Shared definitions. $copilots is the lowercased login list.
JQ_LIB='
def is_copilot:
    if . == null then false
    else (ascii_downcase) as $l | ($copilots | index($l)) != null
    end;

def is_copilot_actor:
    # Takes an author or requestedReviewer object, not a login. Matching on the
    # login alone would treat a human account that happens to be called
    # "copilot" as the reviewer bot, and a human review would then suppress
    # automatic requests. __typename is already in every payload that has an
    # actor; defaulting it to "Bot" keeps payloads captured before it was
    # selected working under --explain.
    (. != null)
    and ((.login? // null) | is_copilot)
    and (((.__typename? // "Bot") == "Bot"));

def is_marked:
    (.reactionGroups // [])
    | any(.viewerHasReacted == true
          and (.content == "THUMBS_UP" or .content == "THUMBS_DOWN" or .content == "EYES"));

def unquoted:
    # Everything a mention does not count in: block quotes, so quoting a request
    # does not re-fire it, then fenced blocks, indented code blocks and inline
    # code spans, because "you can ask @the-handle to re-review" written as
    # documentation is not a request and must not cost a slot.
    #
    # No apostrophes anywhere in this program. It is a single-quoted shell string,
    # so one would end the string and hand the rest to bash.
    (.body // "")
    | split("\n")
    | map(select(test("^ {0,3}>") | not))
    # From an opening fence to the next one. A fold rather than a regex, because a
    # fence spans lines and test() does not.
    | reduce .[] as $line ({ fenced: false, out: [] };
        if ($line | test("^ {0,3}(```|~~~)")) then .fenced = (.fenced | not)
        elif .fenced then .
        else .out += [$line] end)
    | .out
    # An indented code block is 4 or more spaces. A wrapped list item can reach
    # that too, so this drops the occasional real mention. Not answering is the
    # safe direction, because a mention can always be repeated unindented.
    | map(select(test("^ {4,}") | not))
    | join("\n")
    # Inline spans last, so a span cannot hide a newline from the line rules.
    | gsub("`[^`]*`"; "");

def mentions_bot:
    # Bounded on both sides. Without the left boundary an address such as
    # someone@the-handle.example.com reads as a request.
    unquoted | test("(^|[^A-Za-z0-9_-])@" + $handle + "(?![A-Za-z0-9_-])"; "i");

def thread_opener:
    # Q_PR asks for the opening comment as its own aliased connection, so the
    # thread author is known even when the visible comment window has slid
    # past it. The fallback keeps --explain working on payloads captured
    # before that alias existed.
    ((.opener.nodes[0].author?) // (.comments.nodes[0].author?)) // null;
'

# Reduce one pullRequest object to a single tab-separated decision record.
#
# Fields: id  number  is_draft  base_ref  head_oid  has_review  pending
#         threads  unresolved  reviewed_head  new_work  basis  new_count
#         new_oid  new_date  last_review_at  reviewed_oid  state  commit_total
#         mergeable
#
# New fields are appended, never inserted. The record is read positionally here and
# by index in copilot-review-bot-test.sh, so inserting one silently reassigns every
# field after it.
#
# "new_work" is the interesting one. Preferred method is positional: find the
# commit Copilot last reviewed in the PR's commit list and ask whether anything
# after it is a non-merge commit (parents == 1).
#
# The commit is absent from that list for two different reasons, and they need
# different answers. If the PR has more commits than the window, the reviewed one is
# provably at least a window behind the head, so there is new work by definition.
# Otherwise the branch was rewritten - force push, rebase, squash - and the answer is
# inferred from authored dates.
JQ_DECIDE="${JQ_LIB}"'
. as $pr
| (($pr.reviews.nodes // []) | map(select(.author | is_copilot_actor))) as $creviews
| ($creviews | sort_by(.submittedAt // "") | last) as $lastr
| ($lastr.submittedAt // "") as $rtime
| ($lastr.commit.oid // "") as $roid
| (($pr.reviewRequests.nodes // []) | any(.requestedReviewer | is_copilot_actor)) as $pending
| (($pr.commits.nodes // [])
   | map({ oid: .commit.oid,
           merge: ((.commit.parents.totalCount // 1) > 1),
           authored: (.commit.authoredDate // "") })) as $commits
# Absent on a payload captured before totalCount was selected, which is what the
# fallback to the window length is for: it makes $window_exceeded false, so such a
# payload explains exactly as it did before.
| (($pr.commits.totalCount // ($commits | length))) as $commit_total
| (($pr.reviewThreads.nodes // [])
   | map(select(thread_opener | is_copilot_actor))) as $cthreads
| ($cthreads
   | map(select(.isResolved != true
                and (if $ignore_outdated then .isOutdated != true else true end)))
   | length) as $unresolved
| (($lastr != null) and ($roid == $pr.headRefOid)) as $reviewed_head

# Where the reviewed commit sits in the current commit list. Present means the
# branch was appended to and the question is exact.
| ($commits | map(.oid) | index($roid)) as $idx

# Absent for one of two reasons. The PR has more commits than the window, so the
# reviewed one fell off the end; or the branch was rewritten. Only the second is
# ambiguous, so they must not share a basis.
| (($commit_total > ($commits | length))) as $window_exceeded

# Candidate new work. With the anchor present, everything after it. Without it,
# commits *authored* after the review - committer dates are useless here,
# because a rebase stamps every commit with the time of the rebase, which made
# the commit Copilot had already reviewed look brand new.
| (if $lastr == null then []
   elif $idx != null then ($commits[($idx + 1):] | map(select(.merge | not)))
   else ($commits | map(select((.merge | not) and (.authored > $rtime))))
   end) as $new

| (if $lastr == null then "no-review"
   elif $idx != null then "position"
   elif $window_exceeded then "window"
   elif ($new | length) > 0 then "authored"
   elif (($commits | any(.merge | not)) and ($roid != $pr.headRefOid)) then "rewritten"
   else "none"
   end) as $basis

# "rewritten" is the genuinely ambiguous case: the branch was rewritten but
# nothing on it was authored after the review, so this is a rebase or an amend
# and there is no way to tell which from the metadata alone.
#
# "window" is not ambiguous at all. The reviewed commit is behind a full window of
# commits, so whatever else happened there is new work, and the authored-date
# comparison must not get a say: it answers "no" whenever the window happens to hold
# only commits written before the review, which is exactly what a long-lived PR that
# repeatedly merges its base branch produces.
| (if $lastr == null then false
   elif $basis == "window" then true
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
    (if $roid == "" then "-" else $roid end),
    # OPEN when the field is absent, so a payload captured before it was selected
    # still explains under --explain.
    ($pr.state // "OPEN"),
    ($commit_total | tostring),
    # UNKNOWN when absent, for the same reason, and it reads correctly either way:
    # a payload captured before this field existed genuinely does not know.
    ($pr.mergeable // "UNKNOWN") ]
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
    --argjson ignore_outdated "${IGNORE_OUTDATED}"
    --argjson rewrite_triggers "${REWRITE_TRIGGERS_REVIEW}"
    --arg handle "${MENTION_HANDLE}"
)

# The fourth argument, $copilots, completes jq_args. It is the only one that needs jq
# to build, so it is appended from the preflight - after require_binaries - rather
# than here, where a missing jq would produce a raw shell error instead of the event
# that names it.
#
# This is also the one place the comma separated COPILOT_LOGINS becomes the JSON array
# the jq programs expect, so is_copilot and is_copilot_actor need no notion of the
# configuration format. -s reads the whole value rather than a line at a time, so a
# value that somehow carries a newline still yields exactly one array instead of two
# documents and an unparseable --argjson. Blanks around a separator are trimmed and
# empty entries dropped, so "a, b," is the same list as "a,b".
parse_copilot_logins() {
    local list
    list="$(jq -Rsc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))' \
        <<<"${COPILOT_LOGINS}")" || list=""
    # jq -c prints an empty array as exactly this, so no second jq call is needed to
    # tell "no logins at all" from a list.
    if [[ -z "${list}" || "${list}" == "[]" ]]; then
        emit ERROR run.fatal \
            "COPILOT_LOGINS must name at least one login, comma separated, for example 'copilot,github-copilot', not '${COPILOT_LOGINS}'" \
            reason=bad_option setting=COPILOT_LOGINS given="${COPILOT_LOGINS}"
        exit 2
    fi
    jq_args+=(--argjson copilots "${list}")
}

# ---------------------------------------------------------------------------
# GraphQL documents
# ---------------------------------------------------------------------------
Q_REPO_PRS='
query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    defaultBranchRef { name }
    pullRequests(states: OPEN, first: 100, after: $cursor,
                 orderBy: {field: UPDATED_AT, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes { number }
    }
  }
}'

# Everything needed to decide about one PR, in a single round trip.
#
# Every connection here takes the *newest* slice, because every question asked
# of it is about recent state. `last` matters on a heavily discussed PR: the
# oldest hundred threads would hide Copilot's, so an unresolved thread reads as
# resolved and the PR gets a re-review it has not earned. Review threads carry two
# questions at once - who opened it, and does anybody mention the bot in it - which
# want opposite ends of the comment list, so the opener is fetched under its own
# alias.
Q_PR='
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
      number
      isDraft
      # The sweep lists OPEN only, but --pr bypasses the list, so without this a
      # merged or closed PR could have a review requested on it.
      state
      baseRefName
      headRefOid
      # CONFLICTING, MERGEABLE, or UNKNOWN. GitHub computes this in the background and
      # asking is what starts the computation, so UNKNOWN means "no answer yet" rather
      # than anything about the PR. A request needs MERGEABLE: the other two both stop
      # it. See "Conflicts with the base branch" in README.md.
      mergeable
      reviewRequests(first: 100) {
        nodes {
          requestedReviewer {
            __typename
            ... on Bot { login }
            ... on User { login }
          }
        }
      }
      reviews(last: 100) {
        nodes {
          submittedAt
          # __typename so a human account named "copilot" is not mistaken for
          # the reviewer bot. A dismissed review still counts as a review here:
          # see "Known limitations" in README.md.
          author { __typename login }
          commit { oid }
        }
      }
      reviewThreads(last: 100) {
        nodes {
          isResolved
          isOutdated
          # Whoever opened the thread owns it, and that is the only thing this
          # connection is for.
          opener: comments(first: 1) { nodes { author { __typename login } } }
          comments(last: 20) {
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
        # Whether the window slid. Without it, a reviewed commit that is simply
        # older than the newest hundred is indistinguishable from a force push,
        # and the PR is then skipped as a restack on every run forever.
        totalCount
        nodes {
          commit {
            oid
            # authoredDate is when the work was written, and a rebase leaves it
            # alone. That is what makes "is this new work?" answerable after a
            # force push, where a committer date would say everything is new.
            authoredDate
            parents { totalCount }
          }
        }
      }
    }
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

# The review request. By login, not by node id: GitHub owns Copilot's id, and the
# id-based `requestReviews` accepts any well-formed one, so a stale id succeeds, files
# the request against an account that reviews nothing, and leaves the PR looking
# reviewed-pending forever. A login that stops resolving is an error instead.
#
# REVIEWER_FIELD is substituted in, because the three kinds of reviewer are three
# separate input fields rather than one polymorphic list. It is one of three keywords
# settled at startup from the setting, never anything read from GitHub, and the login
# itself travels as a GraphQL variable, so nothing GitHub-supplied reaches the
# document.
#
# union: true adds to the reviewer set. The alternative replaces it, which is what gh
# did, and that needs the current reviewers read first and drops a human reviewer on
# any race between the read and the write.
M_REQUEST_REVIEW='
mutation($pullRequestId: ID!, $login: String!) {
  requestReviewsByLogin(input: {pullRequestId: $pullRequestId,
                                REVIEWER_FIELD: [$login],
                                union: true}) {
    clientMutationId
  }
}'

# ---------------------------------------------------------------------------
# GitHub helpers
# ---------------------------------------------------------------------------
# A read runs inside $( ), so a variable it sets is lost on return. The error text
# goes to a file instead, which survives either way and is rewritten on every call,
# so last_error always reports the freshest failure rather than a stale one.
ERR_FILE=""

set_last_error() {
    [[ -n "${ERR_FILE}" ]] && printf '%s' "$1" >"${ERR_FILE}"
    return 0
}

last_error() {
    [[ -n "${ERR_FILE}" && -s "${ERR_FILE}" ]] && cat "${ERR_FILE}"
    return 0
}

# Will a later run plausibly get a different answer?
#
#   transient  a blip: the remedy is to try again, so nothing about the PR is
#              touched and the run still exits 0.
#   permanent  a settled no: reported on the PR with its error code, and the
#              run exits 1 so somebody looks at it.
#
# GitHub reports its secondary rate limit as a 403, so the transient markers
# are tested first and a 4xx does not veto them. Anything unrecognized is
# permanent: surfacing an unknown error once, loudly, beats retrying it
# silently on every tick with nobody any the wiser.
classify_failure() { # <raw-error>
    if grep -qiE 'HTTP 5[0-9]{2}|HTTP 429|HTTP 408|rate limit|abuse detection|submitted too quickly|time[d]? ?out|deadline exceeded|connection (reset|refused|closed)|broken pipe|unexpected EOF|\bEOF\b|TLS handshake|tls: |temporary failure in name resolution|no such host|server misbehaving|network is (unreachable|down)|i/o timeout|service unavailable|bad gateway|gateway time' <<<"$1"; then
        printf 'transient'
    else
        printf 'permanent'
    fi
}

# Whether to retry a *read* inside this run, which is a different question from
# classify_failure. A read is idempotent, so retrying an unrecognized error
# costs nothing and often works; only a settled refusal is worth giving up on
# immediately, because it will not fix itself in the next nine seconds.
#
# A GraphQL error carries no HTTP status, so the status rules alone would retry
# every NOT_FOUND three times. The `type` from the errors array settles those.
is_retryable() { # <raw-error>
    if grep -qE 'HTTP 429|rate limit|secondary' <<<"$1"; then
        return 0
    fi
    if grep -qE '"type" *: *"(NOT_FOUND|FORBIDDEN|UNAUTHORIZED|INSUFFICIENT_SCOPES|SAML_ENFORCED)"' <<<"$1"; then
        return 1
    fi
    if grep -qE 'HTTP 4[0-9]{2}' <<<"$1"; then
        return 1
    fi
    return 0
}

# gh has no request timeout of its own, so every call goes through timeout(1). A
# connected socket that stops sending bytes would otherwise stall the run until
# the platform kills it, which costs the lock as well as the cycle. Set by
# detect_gh_timeout; empty means unwrapped, which needs bash 4.4 to expand.
GH_TIMEOUT_PREFIX=()

# gh's stdout on success, a one-line summary on failure. The streams are kept
# apart, as handle_pr does for jq and the entrypoint for git: stderr goes to a file
# and is read only once the call has failed. Merged, anything gh writes to stderr
# while still exiting 0 - GH_DEBUG=api, say - becomes part of the payload callers
# parse as JSON.
#
# The failure text is gh's message plus the GraphQL `errors` array, never the
# `data`: a GraphQL error arrives as a whole response body, which for Q_PR is up to
# a hundred comment bodies, and that would both bury the message and copy PR text
# into the log. Exit 124 is timeout(1), which leaves no message of its own.
gh_graphql() { # <query> [gh args...]
    local query="$1" out rc=0 err
    shift
    err="${TMPDIR_RUN:-${TMPDIR:-/tmp}}/gh-stderr"
    out="$("${GH_TIMEOUT_PREFIX[@]}" gh api graphql -f query="${query}" "$@" 2>"${err}")" || rc=$?
    if ((rc == 0)); then
        printf '%s' "${out}"
        return 0
    fi
    ((rc == 124)) && printf 'gh timed out after %ss. ' "${GH_TIMEOUT}"
    printf '%s' "$(tr '\n' ' ' <"${err}" 2>/dev/null || true)"
    # Appended, not substituted: gh's message is the human-readable half and the
    # errors array carries the machine-readable `type` that is_retryable needs.
    printf ' %s' "$(jq -c '.errors // empty' <<<"${out}" 2>/dev/null || true)"
    return "${rc}"
}

# Read-only query with a small retry, since a scheduled job should ride out a
# blip rather than skip a cycle.
gql() {
    local attempt=1 out rc
    while :; do
        rc=0
        out="$(gh_graphql "$@")" || rc=$?
        if ((rc == 0)); then
            printf '%s' "${out}"
            return 0
        fi
        # Through emit, not raw to stderr: a verbatim gh dump is multi-line and
        # often contains GitHub's own JSON, which breaks the one-event-per-line
        # contract every consumer of this log relies on.
        [[ "${verbose}" == true ]] &&
            emit DEBUG gh.error "gh reported an error" attempt#="${attempt}" \
                gh_exit#="${rc}" error="$(error_summary "${out}")"
        if ((attempt >= GH_MAX_ATTEMPTS)) || ! is_retryable "${out}"; then
            set_last_error "${out}"
            return 1
        fi
        ((GH_RETRY_BASE_SECONDS > 0)) && sleep $((attempt * GH_RETRY_BASE_SECONDS))
        attempt=$((attempt + 1))
    done
}

# Mutations are not retried: a partial success would double-post.
mutate() { # <caller-function> [caller args...]
    local caller="$1"
    shift
    local out rc=0
    out="$("${caller}" "$@")" || rc=$?
    # Spacing every mutation, on both outcomes, because GitHub's secondary limits
    # count attempts rather than successes.
    [[ "${SLEEP_BETWEEN_MUTATIONS}" != 0 ]] && sleep "${SLEEP_BETWEEN_MUTATIONS}"
    if ((rc == 0)); then
        set_last_error ""
        return 0
    fi
    set_last_error "${out}"
    return 1
}

gql_mutate() { mutate gh_graphql "$@"; }

# Squeeze a gh/GraphQL failure into one line, keeping any status code or
# error type so it can be reported back on the PR.
error_summary() {
    local raw="$1" code
    code="$(grep -oE 'HTTP [0-9]{3}|FORBIDDEN|UNAUTHORIZED|NOT_FOUND|INSUFFICIENT_SCOPES|SAML_ENFORCED|RATE_LIMITED|MAX_NODE_LIMIT_EXCEEDED' <<<"${raw}" | head -1 || true)"
    raw="$(tr '\n' ' ' <<<"${raw}" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    raw="${raw:0:400}"
    # Only prefix when the text does not already open with the code, or the
    # summary reads "HTTP 403: HTTP 403: ...".
    if [[ -n "${code}" && "${raw}" != "${code}"* ]]; then
        printf '%s: %s' "${code}" "${raw}"
    else
        printf '%s' "${raw}"
    fi
}

# Overridable only so the anonymous probe below can be pointed at a stub. This is
# the one place the bot talks to GitHub without going through gh, so leaving it
# hardcoded would make any test that reaches it depend on the network.
GITHUB_API_ROOT="${GITHUB_API_ROOT:-https://api.github.com}"

# Called when a repository read fails, to turn a bare status code into
# something actionable. Two independent signals: the shape of the token (a
# fine-grained PAT is deny-by-default, which surprises people on public repos)
# and whether the repo reads fine with no credentials at all.
diagnose_access() { # <owner> <name> <raw-error>
    local owner="$1" name="$2" raw="$3" token="" fine_grained=false anon=""

    token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    [[ "${token}" == github_pat_* ]] && fine_grained=true

    if grep -qiE 'HTTP 401|bad credentials' <<<"${raw}"; then
        emit ERROR access.token_rejected \
            "the token was rejected outright: expired, revoked, or mistyped. Check it with: gh api user" \
            reason=bad_credentials remedy=replace_token
        return
    fi
    if grep -qiE 'saml|single.sign.on' <<<"${raw}"; then
        emit ERROR access.sso_required \
            "the token needs SSO authorization for the ${owner} organization; authorize it on the token's own settings page" \
            reason=saml_enforced org="${owner}" remedy=authorize_sso
        return
    fi
    grep -qiE 'HTTP 403|HTTP 404|not accessible|forbidden|could not resolve to a repository' \
        <<<"${raw}" || return 0

    emit ERROR access.denied \
        "the token authenticated but cannot read ${owner}/${name}; GitHub answers 404 rather than 403 for repositories a token cannot see, so either code means the same thing here" \
        reason=not_visible_to_token \
        token_type="$(if [[ "${fine_grained}" == true ]]; then printf 'fine_grained_pat'; else printf 'other'; fi)"

    if [[ "${fine_grained}" == true ]]; then
        emit ERROR access.fine_grained_pat \
            "a fine-grained PAT is deny-by-default and can only see repositories explicitly granted to it, public ones included; re-create it selecting 'Public Repositories (read-only)', or have it granted ${owner}/${name} (which needs the ${owner} org to permit fine-grained tokens and an owner to approve), or use a classic PAT with the 'repo' scope. Filing requests additionally needs Pull requests: Read and write plus the Triage role." \
            reason=fine_grained_deny_by_default org="${owner}" \
            remedy=grant_repo_or_public_read
        return
    fi

    # Not obviously a fine-grained PAT - fall back to comparing against what an
    # anonymous client sees. Inconclusive if unauthenticated calls are
    # themselves being rate limited (60/hour per IP).
    if command -v curl >/dev/null 2>&1; then
        anon="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' \
            -H 'Accept: application/vnd.github+json' \
            "${GITHUB_API_ROOT}/repos/${owner}/${name}" 2>/dev/null || true)"
    fi
    case "${anon}" in
        200) emit ERROR access.anonymous_probe \
            "${owner}/${name} reads fine with no credentials at all, so this is the token's permissions, not the repo or the network" \
            anonymous_status#=200 conclusion=token_permissions ;;
        404) emit ERROR access.anonymous_probe \
            "${owner}/${name} is not readable anonymously either - check the spelling, or it is private and the token lacks access" \
            anonymous_status#=404 conclusion=repo_missing_or_private ;;
        # anonymous_status# with an empty value renders as JSON null, so the field
        # keeps one type across all three branches of this event and a metric on
        # it cannot hit a type conflict. `conclusion` carries the meaning.
        *) emit DEBUG access.anonymous_probe \
            "anonymous read probe was inconclusive" \
            anonymous_status#="" conclusion=inconclusive ;;
    esac
}

# ---------------------------------------------------------------------------
# State: a local directory, or a Cloud Storage bucket
# ---------------------------------------------------------------------------
# One thing has to survive between runs:
#
#   requested.json   { "<owner>/<name>#<pr>": {head, at} } - the head commit
#                    each review request was filed for, so a second request is
#                    not filed in the window before GitHub reports the first
#                    one as pending.
#
# Cloud Run gives each execution a fresh, empty filesystem, so a local
# STATE_DIR there is the same as having no state at all: every marker is lost.
# Setting STATE_DIR to gs://bucket/prefix keeps the object in Cloud Storage
# instead.
#
# One object, so a run costs one GET at startup and one PUT at the end rather than
# a few hundred GETs.
#
# Local state still uses flock. Cloud Storage state takes a lock object with an
# if-generation-match precondition, which is the only kind of mutual exclusion
# that means anything between two Cloud Run executions.
STATE_IS_GCS=false
GCS_BUCKET=""
GCS_PREFIX=""
STATE_LOCAL=""
REQUESTED_FILE=""

declare -A REQUESTED_HEAD=()
declare -A REQUESTED_AT=()
# Keys this run wrote. If another run wins the race to publish, only these are
# overlaid onto its version, so its markers survive and ours are not lost either.
declare -A REQUESTED_WROTE=()
# Generation of requested.json as this run read it, so the write can be made
# conditional. Empty means it could not be determined; 0 means "did not exist".
REQUESTED_GENERATION=""
state_dirty=false
state_loaded=false
# Set when requested.json exists but could not be read. The in-memory table is
# then empty for a reason that is not "there are no markers", so publishing it
# would destroy every stored marker.
markers_unread=false

# Named once, because this expression appeared byte-identical on two events and a
# third would have been a coin toss which spelling it used.
state_backend_name() {
    if [[ "${STATE_IS_GCS}" == true ]]; then printf gcs; else printf local; fi
}

# STATE_DIR is a root shared by every process, and the repository being watched is
# what namespaces it: both the lock and requested.json land under <owner>/<name>. That
# is what lets a fleet of single-repo jobs be pointed at one bucket with nothing
# hand-chosen per job to keep unique. On the gs:// side the nesting is done once here,
# on GCS_PREFIX, because gcs_object() is the single place a bare object name becomes a
# full path, so both objects inherit it.
parse_state_dir() { # <owner> <name>
    if [[ "${STATE_DIR}" != gs://* ]]; then
        STATE_IS_GCS=false
        STATE_LOCAL="${STATE_DIR}/$1/$2"
        [[ -z "${LOCK_FILE}" ]] && LOCK_FILE="${STATE_LOCAL}/lock"
        return 0
    fi
    local rest="${STATE_DIR#gs://}"
    GCS_BUCKET="${rest%%/*}"
    if [[ "${rest}" == */* ]]; then
        GCS_PREFIX="${rest#*/}"
        GCS_PREFIX="${GCS_PREFIX%/}"
    fi
    if [[ -z "${GCS_BUCKET}" ]]; then
        emit ERROR run.fatal \
            "STATE_DIR looks like a Cloud Storage URL but names no bucket: '${STATE_DIR}'" \
            reason=bad_state_dir given="${STATE_DIR}"
        exit 2
    fi
    GCS_PREFIX="${GCS_PREFIX:+${GCS_PREFIX}/}$1/$2"
    STATE_IS_GCS=true
}

# Survivable rather than fatal, so it warns and carries on - but on every run,
# until somebody points STATE_DIR at a bucket.
warn_if_state_is_ephemeral() {
    [[ "${STATE_IS_GCS}" == true ]] && return 0
    [[ -n "${CLOUD_RUN_EXECUTION:-}${K_SERVICE:-}" ]] || return 0
    emit WARNING state.ephemeral \
        "STATE_DIR is a local path on a platform that does not keep one between executions, so no state survives this run and a review request can be filed twice for the same commit. Set STATE_DIR to gs://bucket/prefix." \
        state_dir="${STATE_DIR}" remedy=use_gcs_state_dir
    return 0
}

# Overridable only so the gs:// path can be driven against a stub in the test
# suite. Nothing in production sets it.
GCS_API_ROOT="${GCS_API_ROOT:-https://storage.googleapis.com}"

url_encode() { jq -rn --arg s "$1" '$s|@uri'; }

gcs_object() { # <name>
    printf '%s' "${GCS_PREFIX:+${GCS_PREFIX}/}$1"
}

gcs_url_object() { # <name>
    printf '%s/storage/v1/b/%s/o/%s' "${GCS_API_ROOT}" \
        "$(url_encode "${GCS_BUCKET}")" "$(url_encode "$(gcs_object "$1")")"
}

gcs_url_upload() { # <name>
    printf '%s/upload/storage/v1/b/%s/o?uploadType=media&name=%s' "${GCS_API_ROOT}" \
        "$(url_encode "${GCS_BUCKET}")" "$(url_encode "$(gcs_object "$1")")"
}

# Metadata-server identity. On Cloud Run this is the job's own service account,
# so there is no key file and nothing to rotate: whatever IAM that account has
# on the bucket is what applies.
#
# GOOGLE_OAUTH_ACCESS_TOKEN is the only other source, and it has to be supplied
# deliberately. There is no fall back to `gcloud auth print-access-token`: that
# would make a laptop run against a gs:// STATE_DIR authenticate as whoever is
# logged in, and a non-dry-run laptop run against the production prefix would
# take, and on release delete, the lock the scheduled job relies on. A --dry-run
# takes no lock at all (see acquire_lock), so this risk is specific to a real
# run pointed at the wrong prefix.
#
# The base URL is overridable for the same reason GCS_API_ROOT is: this is the
# only way the bot gets a token in production, so the test suite has to be able
# to point it at a stub. Nothing in production sets it.
metadata_url="${GCS_METADATA_ROOT:-http://metadata.google.internal}/computeMetadata/v1/instance/service-accounts/default"

gcs_token() {
    if [[ -n "${GOOGLE_OAUTH_ACCESS_TOKEN:-}" ]]; then
        printf '%s' "${GOOGLE_OAUTH_ACCESS_TOKEN}"
        return 0
    fi
    local body tok=""
    body="$(curl -sS -m "${GCS_TOKEN_TIMEOUT}" -H 'Metadata-Flavor: Google' \
        "${metadata_url}/token" 2>/dev/null || true)"
    [[ -n "${body}" ]] && tok="$(jq -r '.access_token // empty' <<<"${body}" 2>/dev/null || true)"
    [[ -z "${tok}" ]] && return 1
    printf '%s' "${tok}"
}

# Only consulted to make a permission error name the account that was denied.
gcs_service_account() {
    if [[ -n "${GOOGLE_SERVICE_ACCOUNT:-}" ]]; then
        printf '%s' "${GOOGLE_SERVICE_ACCOUNT}"
        return 0
    fi
    curl -sS -m 5 -H 'Metadata-Flavor: Google' "${metadata_url}/email" 2>/dev/null || true
}

# The token goes in a file rather than on a command line, so it never appears
# in the process table. Refreshed rather than cached, because the final state
# write happens at the end of a run that may have taken a while.
GCS_AUTH_FILE=""
gcs_auth_refresh() {
    local tok
    tok="$(gcs_token)" || {
        emit ERROR gcs.no_token \
            "could not get a Google access token from the metadata server; is this running on Google Cloud with a service account attached?" \
            reason=no_metadata_token
        return 1
    }
    GCS_AUTH_FILE="${TMPDIR_RUN}/gcs-auth"
    (
        umask 077
        printf 'Authorization: Bearer %s\n' "${tok}" >"${GCS_AUTH_FILE}"
    )
}

# One HTTP call, retried on the statuses that mean "ask again". Sets GCS_STATUS
# and leaves the response body in GCS_BODY_FILE and the headers in
# GCS_HEADER_FILE. Must not be called inside $( ), or the assignments are lost.
GCS_STATUS=""
GCS_BODY_FILE=""
GCS_HEADER_FILE=""

# A connection failure, a throttle or a server fault. Anything else is an answer,
# including 404 and 412, which callers here treat as meaningful rather than as
# errors to paper over.
gcs_status_retryable() {
    case "${GCS_STATUS}" in
        000 | 429 | 5??) return 0 ;;
        *) return 1 ;;
    esac
}

gcs_curl() { # <method> <url> [curl args...]
    local method="$1" url="$2"
    shift 2
    local attempt=1
    GCS_BODY_FILE="${TMPDIR_RUN}/gcs-body"
    GCS_HEADER_FILE="${TMPDIR_RUN}/gcs-headers"
    while :; do
        # curl writes %{http_code} even when it fails, so the status comes from -w
        # alone. A fallback appended to this command concatenates onto it rather
        # than replacing it, and "000000" then reaches the operator as the status.
        GCS_STATUS="$(curl -sS -m "${GCS_HTTP_TIMEOUT}" -o "${GCS_BODY_FILE}" \
            -D "${GCS_HEADER_FILE}" -w '%{http_code}' -X "${method}" \
            -H "@${GCS_AUTH_FILE}" "$@" "${url}" 2>/dev/null)" || true
        [[ -n "${GCS_STATUS}" ]] || GCS_STATUS=000
        [[ "${GCS_STATUS}" == 2* ]] && return 0
        if ((attempt >= GCS_MAX_ATTEMPTS)) || ! gcs_status_retryable; then
            return 1
        fi
        emit DEBUG gcs.retry "retrying a Cloud Storage call" \
            method="${method}" http_status="${GCS_STATUS}" attempt#="${attempt}"
        ((GCS_RETRY_BASE_SECONDS > 0)) && sleep $((attempt * GCS_RETRY_BASE_SECONDS))
        attempt=$((attempt + 1))
    done
}

# The generation of whatever the last call touched. An upload answers with the
# object resource, so the body carries it; a media download does not, so the
# x-goog-generation header is the fallback. Empty means it could not be learned,
# which callers treat as "write unconditionally" rather than guessing.
gcs_response_generation() {
    local gen=""
    [[ -s "${GCS_BODY_FILE}" ]] &&
        gen="$(jq -r '.generation // empty' "${GCS_BODY_FILE}" 2>/dev/null || true)"
    if [[ -z "${gen}" && -s "${GCS_HEADER_FILE}" ]]; then
        gen="$(tr -d '\r' <"${GCS_HEADER_FILE}" |
            sed -n 's/^[Xx]-[Gg]oog-[Gg]eneration:[[:space:]]*//p' | tail -1)"
    fi
    printf '%s' "${gen}"
}

# The message GCS puts in its error body, which says far more than the status.
gcs_error_detail() {
    [[ -s "${GCS_BODY_FILE}" ]] || return 0
    jq -r '.error.message // empty' "${GCS_BODY_FILE}" 2>/dev/null |
        head -1 || true
}

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------
# A run that overlaps its predecessor would decide on stale state and, with
# shared state, silently drop the other run's markers when it writes.
lock_acquired=false
LOCK_GENERATION=""
LOCK_HOLDER=""

lock_holder_name() {
    if [[ -n "${CLOUD_RUN_EXECUTION:-}" ]]; then
        printf '%s/task-%s' "${CLOUD_RUN_EXECUTION}" "${CLOUD_RUN_TASK_INDEX:-0}"
    else
        printf '%s/pid-%s' "${HOSTNAME:-$(uname -n 2>/dev/null || echo host)}" "$$"
    fi
}

# Rejected with 412 when the object already exists, which is what makes this a
# mutex rather than a hint. A lock older than LOCK_TTL_MINUTES is broken, so a
# killed run cannot wedge the schedule forever; the break itself is conditional
# on the generation it read, so two runs racing to break cannot both win.
#
# The 412 path reads the object before deciding, because a create whose response was
# lost - a 503 after the write landed, a dropped connection - retries into its own
# object and gets 412. Read as somebody else's lock, that makes the run skip itself
# and leave a lock nobody releases until the TTL.
#
# One `?alt=media` GET answers all three questions, which is why there is no second
# request here to fail on its own: the body is the JSON this function wrote, so it
# carries both the holder and the start time, and the generation comes back as the
# x-goog-generation header. The start time is preferred over the object's own
# timeCreated for exactly that reason - it is in the half of the response that cannot
# go missing.
#
# 0 acquired, 1 held by a live run (skip this run, not an error), 2 the bucket is
# unusable and the run cannot continue.
gcs_lock_acquire() {
    local body="${TMPDIR_RUN}/lock-body" attempt=1 gen="" cutoff="" held_by="" \
        started="" url=""
    LOCK_HOLDER="$(lock_holder_name)"
    jq -n --arg holder "${LOCK_HOLDER}" --arg at "$(timestamp_now)" \
        '{holder: $holder, started_at: $at}' >"${body}"

    while :; do
        if gcs_curl POST "$(gcs_url_upload lock)&ifGenerationMatch=0" \
            -H 'Content-Type: application/json' --data-binary "@${body}"; then
            LOCK_GENERATION="$(gcs_response_generation)"
            lock_acquired=true
            emit DEBUG lock.acquired "took the lock" \
                holder="${LOCK_HOLDER}" generation="${LOCK_GENERATION}"
            return 0
        fi

        if [[ "${GCS_STATUS}" != 412 ]]; then
            emit ERROR run.fatal \
                "cannot write to the state bucket: HTTP ${GCS_STATUS}. $(gcs_error_detail)" \
                reason=state_bucket_unusable bucket="${GCS_BUCKET}" \
                http_status="${GCS_STATUS}" \
                service_account="$(gcs_service_account)" \
                remedy=grant_storage_objectAdmin
            return 2
        fi

        if ! gcs_curl GET "$(gcs_url_object lock)?alt=media"; then
            # Released between the 412 and this read, so there is a lock to take.
            if [[ "${GCS_STATUS}" == 404 ]] && ((attempt < 2)); then
                attempt=2
                continue
            fi
            emit INFO run.skipped "the lock is held and could not be read; exiting" \
                reason=locked http_status="${GCS_STATUS}"
            return 1
        fi
        held_by="$(jq -r '.holder // empty' "${GCS_BODY_FILE}" 2>/dev/null || true)"
        started="$(jq -r '.started_at // empty' "${GCS_BODY_FILE}" 2>/dev/null || true)"
        gen="$(gcs_response_generation)"

        # Ours already? The create landed and its response did not come back.
        # Adopt rather than treat it as a competitor. An unknown generation is not a
        # reason to refuse: gcs_lock_release deletes unconditionally rather than
        # leaving the mutex held, so adopting is always safe.
        if [[ -n "${held_by}" && "${held_by}" == "${LOCK_HOLDER}" ]]; then
            LOCK_GENERATION="${gen}"
            lock_acquired=true
            emit WARNING lock.adopted \
                "this run had already created the lock, so its create response was lost; adopting it rather than skipping the run" \
                holder="${LOCK_HOLDER}" generation="${gen}"
            return 0
        fi

        if ((attempt >= 2)); then
            emit INFO run.skipped \
                "another run took the lock while this one was breaking a stale one; exiting" \
                reason=locked
            return 1
        fi

        cutoff="$(date_minutes_ago "${LOCK_TTL_MINUTES}")"
        # Compared as strings at second resolution, which is all RFC 3339 in a fixed
        # zone needs. A body with no start time is broken rather than respected: it
        # cannot be aged, and respecting an unageable lock would wedge the schedule
        # permanently rather than for one TTL.
        if [[ -n "${started}" && "${started:0:19}" > "${cutoff:0:19}" ]]; then
            emit INFO run.skipped "another run holds the lock; exiting" \
                reason=locked held_since="${started}"
            return 1
        fi
        emit WARNING lock.broken \
            "breaking a lock held since ${started:-an unrecorded time}, which is outside the ${LOCK_TTL_MINUTES} minute limit; the run that took it is presumed dead" \
            held_since="${started}" holder="${held_by}" \
            ttl_minutes#="${LOCK_TTL_MINUTES}"
        url="$(gcs_url_object lock)"
        [[ -n "${gen}" ]] && url+="?ifGenerationMatch=${gen}"
        if ! gcs_curl DELETE "${url}"; then
            emit INFO run.skipped \
                "another run broke the stale lock first; exiting" \
                reason=locked http_status="${GCS_STATUS}"
            return 1
        fi
        attempt=2
    done
}

# Reached only from the exit trap, via release_lock.
# shellcheck disable=SC2329
gcs_lock_release() {
    [[ "${lock_acquired}" == true ]] || return 0
    gcs_auth_refresh || return 0
    local url
    url="$(gcs_url_object lock)"
    if [[ -n "${LOCK_GENERATION}" ]]; then
        url+="?ifGenerationMatch=${LOCK_GENERATION}"
    else
        # Unconditional, deliberately. This races a run that has already broken this
        # lock and taken its own, which costs that run its cycle. Returning without
        # deleting costs *every* run until the TTL expires, and does it silently. The
        # same trade is already made the same way in gcs_state_upload.
        emit WARNING lock.release_unconditional \
            "the lock generation was never learned, so the lock is being released without a precondition rather than left behind" \
            holder="${LOCK_HOLDER}"
    fi
    if ! gcs_curl DELETE "${url}"; then
        if [[ "${GCS_STATUS}" == 412 ]]; then
            # The lock this run held is gone and a newer one is in its place, so the
            # TTL it will expire under is not this run's.
            emit WARNING lock.release_failed \
                "the lock had already been broken by another run, so this run overran the ${LOCK_TTL_MINUTES} minute limit" \
                http_status#=412 ttl_minutes#="${LOCK_TTL_MINUTES}"
        else
            emit WARNING lock.release_failed \
                "could not release the lock: HTTP ${GCS_STATUS}. It expires after ${LOCK_TTL_MINUTES} minutes." \
                http_status="${GCS_STATUS}" ttl_minutes#="${LOCK_TTL_MINUTES}"
        fi
    fi
    lock_acquired=false
}

# flock is enough for a local state directory: everything that shares it also
# shares the kernel holding the lock.
# 0 acquired, 1 held by a live run (skip this run, not an error), 2 fatal.
flock_acquire() {
    # Both guarded, because a read-only or missing parent directory otherwise dies on
    # the redirect with a raw bash error on stderr, which is both unactionable and not
    # a JSON event. The redirection has to be on a group: `exec 9>f 2>/dev/null`
    # applies its redirections left to right and so fails before the second one is in
    # place.
    if ! mkdir -p "$(dirname "${LOCK_FILE}")" 2>/dev/null ||
        ! { exec 9>"${LOCK_FILE}"; } 2>/dev/null; then
        emit ERROR run.fatal \
            "cannot create the lock file, so this run cannot guarantee it is the only one; check that the state directory exists and is writable" \
            reason=lock_unwritable lock_file="${LOCK_FILE}"
        return 2
    fi
    local status=0
    flock -n 9 || status=$?
    case "${status}" in
        0)
            lock_acquired=true
            return 0
            ;;
        126 | 127)
            emit ERROR run.fatal \
                "flock could not be executed; refusing to run unlocked. Fix: $(install_hint flock)" \
                reason=flock_unusable lock_status#="${status}"
            return 2
            ;;
        *)
            emit INFO run.skipped "another instance is running; exiting" \
                reason=locked lock_status#="${status}"
            return 1
            ;;
    esac
}

# 0 acquired, 1 held by a live run (skip this run, not an error), 2 fatal. main
# decodes these three at the call site, so they have to mean the same thing in both
# backends.
#
# A dry run makes no mutation and writes no marker, which is everything the lock
# exists to protect (see state_save and the mutation helpers, all gated on
# dry_run the same way). Taking it anyway bought nothing and cost a real hazard:
# a --dry-run pointed at the production gs:// prefix took the lock the scheduled
# job needs and deleted it on release. Skipping it here removes that hazard.
acquire_lock() {
    if [[ "${dry_run}" == true ]]; then
        emit DEBUG lock.skipped \
            "a dry run makes no writes, so it takes no lock" \
            reason=dry_run
        return 0
    fi
    if [[ "${STATE_IS_GCS}" == true ]]; then
        gcs_lock_acquire
    else
        flock_acquire
    fi
}

# Reached only from the exit trap. flock needs no counterpart: the kernel drops
# it when the process goes away.
# shellcheck disable=SC2329
release_lock() {
    [[ "${STATE_IS_GCS}" == true ]] && gcs_lock_release
    return 0
}

# ---------------------------------------------------------------------------
# State load and save
# ---------------------------------------------------------------------------
state_load() {
    if [[ "${STATE_IS_GCS}" == true ]]; then
        STATE_LOCAL="${TMPDIR_RUN}/state"
    fi
    if ! mkdir -p "${STATE_LOCAL}" 2>/dev/null; then
        emit ERROR run.fatal "cannot create the state directory" \
            reason=state_dir_unwritable path="${STATE_LOCAL}"
        exit 2
    fi
    REQUESTED_FILE="${STATE_LOCAL}/requested.json"

    if [[ "${STATE_IS_GCS}" == true ]]; then
        # A 404 just means this is a first run. The bucket itself is already
        # proven, because the lock was written to it.
        if gcs_curl GET "$(gcs_url_object requested.json)?alt=media"; then
            cp "${GCS_BODY_FILE}" "${REQUESTED_FILE}" 2>/dev/null || markers_unread=true
            REQUESTED_GENERATION="$(gcs_response_generation)"
        elif [[ "${GCS_STATUS}" == 404 ]]; then
            # No object yet, so the write may only create one.
            REQUESTED_GENERATION=0
        else
            # Not the same as "no markers": the object may hold every marker from
            # every previous run. Latched so state_save leaves it alone instead of
            # publishing this run's handful over the top of it.
            markers_unread=true
            emit WARNING state.read_failed \
                "could not read the stored markers, so they will be left alone rather than replaced at the end of this run" \
                object=requested.json http_status="${GCS_STATUS}"
        fi
    fi

    local key head at count=0
    if [[ -s "${REQUESTED_FILE}" ]]; then
        # Whether the file parses is a separate question from whether it holds
        # anything. An empty object is a legitimate state, and reporting it as
        # corruption sent people looking for a problem that was not there.
        if ! jq -e 'type == "object"' "${REQUESTED_FILE}" >/dev/null 2>&1; then
            emit WARNING state.unreadable \
                "the stored markers are not a JSON object and are being ignored; at worst one extra review request is filed per PR" \
                object=requested.json
        else
            while IFS=$'\t' read -r key head at; do
                [[ -z "${key}" ]] && continue
                REQUESTED_HEAD["${key}"]="${head}"
                REQUESTED_AT["${key}"]="${at}"
                count=$((count + 1))
            done < <(jq -r 'to_entries[]? | [.key, (.value.head // ""), (.value.at // "")] | @tsv' \
                "${REQUESTED_FILE}" 2>/dev/null || true)
        fi
    fi
    state_loaded=true
    emit DEBUG state.loaded "state loaded" \
        backend="$(state_backend_name)" \
        location="${STATE_DIR}" markers#="${count}"
}

# Render the in-memory markers as the stored JSON object, dropping anything past
# MARKER_MAX_AGE_DAYS. mode "mine" keeps only what this run wrote, which is what
# a merge after a lost race overlays.
state_marker_json() { # <all|mine> <out-file>
    local mode="$1" out="$2" cutoff k
    cutoff="$(date_days_ago "${MARKER_MAX_AGE_DAYS}")"
    # stderr is suppressed because it is the same stream the events go to: an
    # unwritable destination makes the shell print a raw "cannot create" line,
    # which is not JSON and would break the log contract. The caller reports the
    # failure as an event instead.
    (
        {
            for k in "${!REQUESTED_HEAD[@]}"; do
                if [[ "${mode}" == mine && -z "${REQUESTED_WROTE[${k}]:-}" ]]; then
                    continue
                fi
                printf '%s\t%s\t%s\n' "${k}" "${REQUESTED_HEAD[${k}]}" "${REQUESTED_AT[${k}]:-}"
            done
        } | jq -R -s --arg cutoff "${cutoff}" '
                split("\n") | map(select(length > 0) | split("\t"))
                | map(select((.[2] // "") >= $cutoff))
                | map({ key: .[0], value: { head: .[1], at: .[2] } })
                | from_entries' >"${out}"
    ) 2>/dev/null
}

# Publish the markers, conditional on the generation this run read. Without the
# precondition a slow run whose lock had already been broken would overwrite the
# run that took over from it. On 412 the two views are merged rather than one
# winning: the other run's object is taken as the base and only the keys this run
# actually wrote are overlaid.
gcs_state_upload() { # <file>
    local file="$1" attempt=1 url merged mine
    while :; do
        gcs_auth_refresh || return 1
        url="$(gcs_url_upload requested.json)"
        # An unknown generation means the precondition cannot be formed, so the
        # write is unconditional. Better a small race than refusing to save.
        [[ -n "${REQUESTED_GENERATION}" ]] &&
            url+="&ifGenerationMatch=${REQUESTED_GENERATION}"
        if gcs_curl POST "${url}" \
            -H 'Content-Type: application/json' --data-binary "@${file}"; then
            REQUESTED_GENERATION="$(gcs_response_generation)"
            return 0
        fi
        if [[ "${GCS_STATUS}" != 412 ]] || ((attempt >= 2)); then
            emit ERROR state.write_failed \
                "could not store the markers: HTTP ${GCS_STATUS}. $(gcs_error_detail) The next run may re-file a request GitHub already has, which is a wasted call rather than a duplicate review." \
                object=requested.json http_status="${GCS_STATUS}"
            return 1
        fi
        emit WARNING state.write_conflict \
            "another run published markers while this one was working, so the two sets are being merged and the write retried" \
            object=requested.json http_status#=412
        if ! gcs_curl GET "$(gcs_url_object requested.json)?alt=media"; then
            emit ERROR state.write_failed \
                "could not re-read the markers after a write conflict" \
                object=requested.json http_status="${GCS_STATUS}"
            return 1
        fi
        REQUESTED_GENERATION="$(gcs_response_generation)"
        merged="${TMPDIR_RUN}/requested-merged.json"
        mine="${TMPDIR_RUN}/requested-mine.json"
        cp "${GCS_BODY_FILE}" "${TMPDIR_RUN}/requested-theirs.json"
        state_marker_json mine "${mine}"
        if ! jq -s '(.[0] // {}) * (.[1] // {})' \
            "${TMPDIR_RUN}/requested-theirs.json" "${mine}" >"${merged}"; then
            emit ERROR state.write_failed "could not merge the markers" \
                object=requested.json
            return 1
        fi
        file="${merged}"
        attempt=$((attempt + 1))
    done
}

# Called once from main, and again from the exit trap in case main never got
# there. Clearing state_dirty up front makes the second call a no-op, so a write
# failure is reported once rather than twice.
state_save() {
    [[ "${state_loaded}" == true ]] || return 0
    [[ "${state_dirty}" == true ]] || return 0
    [[ "${dry_run}" == true ]] && return 0
    state_dirty=false

    if [[ "${markers_unread}" == true ]]; then
        emit WARNING state.write_skipped \
            "the stored markers could not be read this run, so they are left alone rather than replaced; the next run may re-file a request GitHub already has, which is a wasted call rather than a duplicate review" \
            object=requested.json
        return 0
    fi

    # Built beside its destination in local mode, so the rename that publishes it
    # is atomic and cannot leave a half-written marker file behind. The run
    # directory is usually a different filesystem, where a rename is a copy.
    local tmp
    if [[ "${STATE_IS_GCS}" == true ]]; then
        tmp="${TMPDIR_RUN}/requested-new.json"
    else
        tmp="${REQUESTED_FILE}.tmp"
    fi
    if ! state_marker_json all "${tmp}"; then
        emit ERROR state.write_failed "could not build the marker file" \
            object=requested.json path="${tmp}"
        rm -f "${tmp}"
        exit_status=1
        return 1
    fi

    if [[ "${STATE_IS_GCS}" == true ]]; then
        if ! gcs_state_upload "${tmp}"; then
            exit_status=1
            return 1
        fi
    elif ! mv "${tmp}" "${REQUESTED_FILE}"; then
        emit ERROR state.write_failed \
            "could not write the marker file. The next run may re-file a request GitHub already has, which is a wasted call rather than a duplicate review." \
            path="${REQUESTED_FILE}"
        rm -f "${tmp}"
        exit_status=1
        return 1
    fi
    emit DEBUG state.saved "state saved" markers#="${#REQUESTED_HEAD[@]}"
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
# Nothing further can be filed once the budget is gone, either because the cap
# is reached or because repeated transient failures halted requests. Under
# --dry-run the counter never moves, so a dry run always walks every PR and
# reports the full inventory.
requests_exhausted() {
    [[ "${requests_halted}" == true ]] && return 0
    ((request_attempts >= MAX_REQUESTS_PER_RUN))
}

# Why the run stopped asking: prose for the message, a code for filtering.
#
# halt_reason covers only the request breakers. stop_reason is the wider question
# "why did the sweep stop", which the read breaker and the run deadline also
# answer, and they must not be reported as the request cap: a repo skipped because
# GitHub was unreadable must not be reported as the request cap.
stop_reason=""

budget_reason_code() {
    if [[ "${requests_halted}" == true ]]; then
        printf '%s' "${halt_reason:-requests_halted}"
    else
        printf '%s' "${stop_reason:-run_limit}"
    fi
}

# Why the *sweep* stopped, which is what run.done reports. stop_reason wins over
# halt_reason here, the opposite way round from budget_reason_code: a run that halted
# requests on transient failures and then abandoned the sweep on read failures has to
# report the read failures, or a dashboard counting them from run.done undercounts.
stop_reason_code() {
    if [[ -n "${stop_reason}" ]]; then
        printf '%s' "${stop_reason}"
    elif [[ "${requests_halted}" == true ]]; then
        printf '%s' "${halt_reason:-requests_halted}"
    else
        printf '%s' run_limit
    fi
}

budget_reason() {
    if [[ "${requests_halted}" != true ]]; then
        case "${stop_reason}" in
            read_failures)
                printf 'the sweep was abandoned after repeated read failures, so GitHub looked unhealthy'
                return
                ;;
            run_deadline)
                printf 'the run deadline of %ss was reached' "${RUN_DEADLINE_SECONDS}"
                return
                ;;
        esac
    fi
    case "${halt_reason}" in
        transient_failures)
            printf 'requests were halted after repeated transient failures'
            ;;
        permanent_failures)
            printf 'requests were halted after repeated permanent failures, which usually means a repo-wide permission or licensing problem rather than anything about these PRs'
            ;;
        *)
            printf 'the run limit of %s review requests is reached' "${MAX_REQUESTS_PER_RUN}"
            ;;
    esac
}

# True once the run has used its wall-clock budget. Latched, so the reason
# reaches run.done even though the loops break immediately.
run_deadline_reached() {
    ((RUN_DEADLINE_SECONDS > 0)) || return 1
    ((SECONDS < RUN_DEADLINE_SECONDS)) && return 1
    deadline_hit=true
    return 0
}

# Markers stop a second request for the same head commit if GitHub has not
# (yet) surfaced the pending review request.
marker_key() { # <owner> <name> <pr>
    printf '%s/%s#%s' "$1" "$2" "$3"
}

marker_matches() { # <key> <head-oid>
    local key="$1" head="$2"
    [[ -n "${head}" ]] && [[ "${REQUESTED_HEAD[${key}]:-}" == "${head}" ]]
}

marker_write() { # <key> <head-oid>
    [[ "${dry_run}" == true ]] && return 0
    local key="$1" head="$2"
    REQUESTED_HEAD["${key}"]="${head}"
    REQUESTED_AT["${key}"]="$(timestamp_now)"
    REQUESTED_WROTE["${key}"]=1
    state_dirty=true
}

# Files the review request.
#   0 - requested (or would have been, under --dry-run)
#   1 - failed permanently; REQUEST_ERROR holds a one-line summary
#   2 - deferred because the per-run cap is reached, or because requests have
#       been halted for this run. Not a failure: the next run picks it up.
#   3 - failed transiently (5xx, rate limit, network). Also picked up by the
#       next run, so it must not consume a mention either: a thumbs-down would
#       mark that comment answered forever over a blip.
#
# The class is settled here, before the PR is touched, because the reaction
# that gets applied is a permanent record of a decision that may not be.
REQUEST_ERROR=""
REQUEST_CLASS=""
# The PR is named by its node id and nothing else, because that is all the mutation
# takes: the repository is implicit in the id, and the number is already on every
# event through ctx_pr.
request_review() { # <pr-id>
    local pr_id="$1"
    REQUEST_ERROR=""
    REQUEST_CLASS=""

    if requests_exhausted; then
        deferrals=$((deferrals + 1))
        # The scan stops as soon as the budget runs out, so this is announced
        # once per run at most. The remaining PRs are never even fetched.
        if [[ "${cap_announced}" != true ]]; then
            cap_announced=true
            emit WARNING review.deferred \
                "$(budget_reason); deferring to the next run" \
                reason="$(budget_reason_code)" limit#="${MAX_REQUESTS_PER_RUN}"
        else
            emit DEBUG review.deferred "deferred to the next run" \
                reason="$(budget_reason_code)" limit#="${MAX_REQUESTS_PER_RUN}"
        fi
        return 2
    fi

    if [[ "${dry_run}" == true ]]; then
        would_request=$((would_request + 1))
        return 0
    fi

    # Counted before the call, so a failure consumes the budget too.
    request_attempts=$((request_attempts + 1))

    # One mutation, carrying a login and no node id for the reviewer, additive rather
    # than replacing. See M_REQUEST_REVIEW for each of those three choices, and
    # "Asking Copilot, by name" in README.md for why this is not `gh pr edit`.
    if gql_mutate "${M_REQUEST_REVIEW/REVIEWER_FIELD/${REVIEWER_FIELD}}" \
        -f pullRequestId="${pr_id}" -f login="${REVIEWER}"; then
        requests_made=$((requests_made + 1))
        consecutive_transients=0
        consecutive_permanents=0
        return 0
    fi

    REQUEST_ERROR="$(error_summary "$(last_error)")"
    REQUEST_CLASS="$(classify_failure "$(last_error)")"

    if [[ "${REQUEST_CLASS}" == transient ]]; then
        transients=$((transients + 1))
        consecutive_permanents=0
        consecutive_transients=$((consecutive_transients + 1))
        if ((consecutive_transients >= MAX_CONSECUTIVE_TRANSIENT)); then
            requests_halted=true
            halt_reason=transient_failures
            emit WARNING requests.halted \
                "halting review requests for this run after consecutive transient failures; the remaining PRs are deferred to the next run" \
                consecutive_transient_failures#="${consecutive_transients}" \
                threshold#="${MAX_CONSECUTIVE_TRANSIENT}"
        fi
        return 3
    fi

    # A permanent failure is nearly always a repo-wide fact, so stop rather than
    # repeating the same rejected write once per open PR.
    consecutive_transients=0
    consecutive_permanents=$((consecutive_permanents + 1))
    if ((consecutive_permanents >= MAX_CONSECUTIVE_PERMANENT)); then
        requests_halted=true
        halt_reason=permanent_failures
        emit ERROR requests.halted \
            "halting review requests for this run after consecutive permanent failures; this is usually the account losing the Triage role, Copilot having no seat on the repo, or ${REVIEWER} no longer resolving, rather than anything about these PRs" \
            consecutive_permanent_failures#="${consecutive_permanents}" \
            threshold#="${MAX_CONSECUTIVE_PERMANENT}" \
            reviewer="${REVIEWER}" reviewer_field="${REVIEWER_FIELD}" \
            error="${REQUEST_ERROR}" remedy=check_role_seat_and_reviewer
    fi
    return 1
}

# 0 added (or nothing to do), 1 failed permanently, 3 failed transiently. The
# split matters because the caller sets exit_status from it, and a 502 on a
# reaction is not something a human needs to look at.
react() { # <subject-id> <THUMBS_UP|THUMBS_DOWN|EYES>
    if [[ "${dry_run}" == true ]]; then
        emit INFO reaction.added "reaction not added, this is a dry run" \
            reaction="$2" dry_run#=true
        return 0
    fi
    if ! gql_mutate "${M_ADD_REACTION}" -f subjectId="$1" -f content="$2"; then
        # A duplicate reaction is not worth escalating. Matched on the whole phrase
        # rather than on "already" alone: that word also appears in errors that are
        # real failures ("has already been archived"), and treating one of those as
        # success marks the mention answered forever.
        if grep -qiE 'already (exists|been (taken|added))' <<<"$(last_error)"; then
            emit DEBUG reaction.exists "reaction already present" reaction="$2"
            return 0
        fi
        local class
        class="$(classify_failure "$(last_error)")"
        # Severity follows the class, as review.request_failed does. The permanent case
        # sets exit_status, so the one line describing what to look at must not be a
        # WARNING while the run reports failure.
        emit "$(if [[ "${class}" == transient ]]; then printf WARNING; else printf ERROR; fi)" \
            reaction.failed "could not add the reaction" \
            reaction="$2" failure_class="${class}" \
            retryable#="$(if [[ "${class}" == transient ]]; then printf true; else printf false; fi)" \
            error="$(error_summary "$(last_error)")"
        [[ "${class}" == transient ]] && return 3
        return 1
    fi
    # INFO, not DEBUG: a reaction is visible to everyone on the PR. comment_id is
    # here so mention.answering can stay at DEBUG and this line still says which
    # comment was marked.
    emit INFO reaction.added "reaction added" \
        reaction="$2" comment_id="$1" dry_run#=false
    return 0
}

post_comment() { # <pr-id> <body>
    if [[ "${dry_run}" == true ]]; then
        emit INFO comment.posted "comment not posted, this is a dry run" \
            body="$2" dry_run#=true
        return 0
    fi
    if ! gql_mutate "${M_ADD_COMMENT}" -f subjectId="$1" -f body="$2"; then
        emit WARNING comment.failed "could not post the comment" \
            error="$(error_summary "$(last_error)")"
        return 1
    fi
    # A comment is visible to everyone on the PR, so it is worth an event even
    # when it worked.
    emit INFO comment.posted "comment posted" body="$2" dry_run#=false
    return 0
}

# ---------------------------------------------------------------------------
# Per-PR handling
# ---------------------------------------------------------------------------
# The decision record uses 1/0 flags; logs read better as real booleans.
bool_json() { if [[ "$1" == 1 ]]; then printf 'true'; else printf 'false'; fi; }

# handle_pr sets the PR log context and has many early returns, so the context
# is cleared here rather than at each of them.
decide_pr() { # <owner> <name> <base-branch> <pr-json-file>
    handle_pr "$@"
    ctx_pr=""
    # The payload is finished with, and on Cloud Run the filesystem is memory:
    # keeping every PR's until the exit trap grows linearly with the repo.
    rm -f "$4"
}

# Why a request is due: prose for the message, a code for filtering. Spelling out
# which commit drove the decision, and how it was established, is what makes a
# wrong call auditable from the log alone. Sets WHY and WHY_CODE.
WHY=""
WHY_CODE=""
describe_basis() { # <basis> <threads> <new-count> <reviewed-oid> <new-oid> <new-date> <last-review-at> <commit-total>
    local basis="$1" threads="$2" new_count="$3" reviewed_oid="$4" new_oid="$5" \
        new_date="$6" last_review_at="$7" commit_total="$8"
    case "${basis}" in
        position)
            WHY="${threads} Copilot thread(s), all resolved; ${new_count}"
            WHY+=" non-merge commit(s) added after the reviewed commit"
            WHY+=" ${reviewed_oid:0:8}, newest ${new_oid:0:8}"
            WHY_CODE=new_commits_after_reviewed
            ;;
        window)
            WHY="${threads} Copilot thread(s), all resolved; the reviewed commit"
            WHY+=" ${reviewed_oid:0:8} is not among the 100 most recent of this"
            WHY+=" PR's ${commit_total} commits, so it is at least 100 commits"
            WHY+=" behind the head"
            WHY_CODE=reviewed_commit_behind_window
            ;;
        # "rewritten" rather than "the branch was rewritten": the reviewed commit
        # being absent from the window is the observation, and a rewrite is only the
        # likeliest explanation for it.
        authored)
            WHY="${threads} Copilot thread(s), all resolved; the reviewed commit"
            WHY+=" ${reviewed_oid:0:8} is not among the commits examined, and"
            WHY+=" ${new_count} non-merge commit(s) were authored after"
            WHY+=" ${last_review_at} (newest ${new_oid:0:8}, authored ${new_date})"
            WHY_CODE=new_commits_authored_after_review
            ;;
        rewritten)
            WHY="${threads} Copilot thread(s), all resolved; the reviewed commit"
            WHY+=" ${reviewed_oid:0:8} is not among the commits examined and"
            WHY+=" nothing was authored after it - a restack or an amend,"
            WHY+=" counted as new work because REWRITE_TRIGGERS_REVIEW=true"
            WHY_CODE=rewritten_counted_as_new_work
            ;;
        # Unreachable: new_work is only true for the three above. A guard rather
        # than a message, so an unhandled basis cannot pass for a real reason.
        *)
            WHY="internal error: unhandled basis '${basis}'"
            WHY_CODE=internal_unhandled_basis
            ;;
    esac
}

# Emit the single event that describes how a review request turned out, and do
# the bookkeeping that follows from it. One event name per outcome, with
# `trigger` distinguishing a mention from the scheduled sweep, so a filter on
# `event` covers both paths.
#
# Returns <rc> unchanged, because the caller still owns the part that genuinely
# differs between the two paths: what reaction, if any, to leave on a comment.
report_request_outcome() { # <rc> <trigger> <marker-key> <head-oid> [attrs...]
    local rc="$1" trigger="$2" marker="$3" head="$4"
    shift 4
    case "${rc}" in
        0)
            # The message follows the flag, as reaction.added and comment.posted
            # already do. A dry run that says "requested" contradicts its own
            # run.done, which says "would be filed".
            emit INFO review.requested \
                "$(if [[ "${dry_run}" == true ]]; then
                    printf 'Copilot review not requested, this is a dry run'
                else printf 'Copilot review requested'; fi)" \
                trigger="${trigger}" "$@" dry_run#="${dry_run}"
            marker_write "${marker}" "${head}"
            ;;
        2)
            # request_review has already emitted review.deferred with the reason
            # the budget ran out. A second one here would double every count and
            # give `reason` two meanings under one event name.
            ;;
        3)
            emit WARNING review.request_failed \
                "transient failure requesting a Copilot review, will retry on the next run" \
                trigger="${trigger}" "$@" failure_class=transient retryable#=true \
                error="${REQUEST_ERROR}"
            if [[ "${TRANSIENT_FAILURES_ARE_ERRORS}" == true ]]; then
                exit_status=1
            fi
            ;;
        *)
            emit ERROR review.request_failed "failed to request a Copilot review" \
                trigger="${trigger}" "$@" failure_class=permanent retryable#=false \
                error="${REQUEST_ERROR}"
            exit_status=1
            ;;
    esac
    return "${rc}"
}

# Whether another reaction or error comment may be written this run. Bounded for the
# two reasons requests are: a per-run cap, so one heavily discussed PR cannot spend the
# whole task timeout one mutation and one sleep at a time, and a consecutive-permanent
# breaker, so a token that has lost write access is reported once rather than once per
# mention. An unreacted comment is already the state the next run treats as
# outstanding, so stopping early loses nothing.
mention_writes_exhausted() {
    [[ "${mention_writes_halted}" == true ]] && return 0
    ((mention_writes >= MAX_MENTION_WRITES_PER_RUN))
}

# Answer every unhandled @handle mention on one PR.
#
# 0  nothing to answer, or answered with EYES: carry on to the automatic checks,
#    which reach the same conclusion and skip.
# 1  this PR is settled for this run, and the caller must not fall through. Either a
#    request was attempted for it - falling through would file it twice and burn
#    another slot - or the mention scan itself failed, or the request was deferred,
#    failed transiently, or is held on a conflict, and the next run should see the
#    mention as outstanding.
handle_mentions() { # <pr-id> <marker> <head-oid> <reviewed-head> <pending> <mergeable> <file>
    local pr_id="$1" marker="$2" head_oid="$3" \
        reviewed_head="$4" pending="$5" mergeable="$6" file="$7"
    local mentions="" attempted=false result=""
    local jq_err="${TMPDIR_RUN}/jq-error"
    # Guarded like the decision above: an unguarded assignment propagates a jq
    # failure straight out of the script, with no event logged.
    if ! mentions="$(jq -r "${jq_args[@]}" --arg viewer "${viewer}" \
        --arg since "${MENTION_SINCE}" "${JQ_MENTIONS}" "${file}" 2>"${jq_err}")"; then
        emit ERROR pr.mentions_failed "could not scan the PR for mentions" \
            file="${file}" error="$(error_summary "$(head -3 "${jq_err}" 2>/dev/null || true)")"
        exit_status=1
        return 1
    fi
    [[ -n "${mentions}" ]] || return 0

    # Decide once for the PR, then answer every unhandled mention on it.
    local want_request=true reason="" reason_code=""
    if [[ "${reviewed_head}" == 1 ]]; then
        want_request=false
        reason="Copilot has already reviewed the head commit"
        reason_code=already_reviewed_head
    elif [[ "${pending}" == 1 ]]; then
        want_request=false
        reason="a Copilot review is already pending on this PR"
        reason_code=request_pending
    elif [[ "${mergeable}" != MERGEABLE ]]; then
        # A mention bypasses the draft and base-branch gates, because somebody asking
        # by name has overridden the policy those two encode. It does not bypass this
        # one: a review of a diff that cannot merge, or that GitHub cannot confirm
        # merges, is of no use to whoever asked. Same rule as the automatic path.
        #
        # Tested after the two above, not before, so a conflicting PR that Copilot has
        # already reviewed still answers EYES. The asker has their review, and holding
        # their comment for a conflict they may never fix would leave it unanswered
        # forever.
        #
        # This is the one outcome that writes no reaction, which is how every unsettled
        # outcome is handled here. Once the branch merges cleanly, the next run sees the
        # mention still outstanding and honors it with no second ask. A reaction is
        # permanent bookkeeping, so it would close a request that was never served. If
        # it never merges cleanly, the mention ages out of the --mention-age window on
        # its own.
        if [[ "${mergeable}" == CONFLICTING ]]; then
            emit DEBUG mention.deferred \
                "mention left outstanding: the branch conflicts with the base branch" \
                trigger=mention reason=conflicting mergeable="${mergeable}"
        else
            emit DEBUG mention.deferred \
                "mention left outstanding: GitHub has not established whether the branch merges cleanly" \
                trigger=mention reason=mergeable_unknown mergeable="${mergeable}"
        fi
        return 1
    fi

    if [[ "${want_request}" == true ]]; then
        local rc=0
        request_review "${pr_id}" || rc=$?
        report_request_outcome "${rc}" mention "${marker}" "${head_oid}" \
            handle="${MENTION_HANDLE}" head="${head_oid}" || true
        case "${rc}" in
            0)
                attempted=true
                result=THUMBS_UP
                ;;
            2 | 3)
                # Neither outcome is settled, so the comment is left unreacted and
                # the next run still sees it as outstanding: a reaction is permanent
                # and a 502 or a deferral is not.
                return 1
                ;;
            *)
                attempted=true
                result=THUMBS_DOWN
                ;;
        esac
    else
        emit DEBUG mention.no_action "mention needs no action: ${reason}" \
            trigger=mention reason="${reason_code}" reaction=EYES
        result=EYES
    fi

    local cid="" kind="" created="" author="" react_rc=0
    while IFS=$'\t' read -r cid kind created author; do
        [[ -z "${cid}" ]] && continue
        if mention_writes_exhausted; then
            if [[ "${mention_cap_announced}" != true ]]; then
                mention_cap_announced=true
                emit WARNING mention.writes_halted \
                    "no more reactions will be written this run; the remaining mentions stay unanswered and the next run picks them up" \
                    reason="$(if [[ "${mention_writes_halted}" == true ]]; then
                        printf permanent_failures
                    else printf write_cap; fi)" \
                    written#="${mention_writes}" limit#="${MAX_MENTION_WRITES_PER_RUN}"
            fi
            break
        fi
        emit DEBUG mention.answering "answering a mention" \
            reaction="${result}" comment_id="${cid}" comment_kind="${kind}" \
            comment_author="${author}" comment_created_at="${created}"
        react_rc=0
        mention_writes=$((mention_writes + 1))
        react "${cid}" "${result}" || react_rc=$?
        # A transient reaction failure leaves the comment unreacted, which is
        # exactly the state the next run treats as still outstanding, so it
        # only fails the run if the operator asked for that.
        if ((react_rc == 3)); then
            consecutive_mention_permanents=0
            [[ "${TRANSIENT_FAILURES_ARE_ERRORS}" == true ]] && exit_status=1
        elif ((react_rc != 0)); then
            exit_status=1
            consecutive_mention_permanents=$((consecutive_mention_permanents + 1))
            # Nearly always repo-wide - the token lost Issues: write, say - so there is
            # nothing to learn from failing the same way once per remaining mention.
            if ((consecutive_mention_permanents >= MAX_CONSECUTIVE_PERMANENT)); then
                mention_writes_halted=true
            fi
        else
            consecutive_mention_permanents=0
        fi
    done <<<"${mentions}"

    if [[ "${result}" == THUMBS_DOWN ]] && ! mention_writes_exhausted; then
        mention_writes=$((mention_writes + 1))
        post_comment "${pr_id}" \
            "@${MENTION_HANDLE} could not request a Copilot review: \`${REQUEST_ERROR}\`" ||
            true
    fi

    # Settled for this run: falling through would file the same request twice. Only
    # an EYES outcome, meaning nothing to do, continues to the automatic checks.
    [[ "${attempted}" == true ]] && return 1
    return 0
}

handle_pr() { # <owner> <name> <base-branch> <pr-json-file>
    local owner="$1" name="$2" base="$3" file="$4"
    local decision="" marker=""

    ctx_repo="${owner}/${name}"
    ctx_pr=""
    # jq's own error goes to a file, not to stderr: stderr is the same stream the
    # events go to, and a raw multi-line jq message there breaks the
    # one-JSON-object-per-line contract every consumer of this log relies on.
    local jq_err="${TMPDIR_RUN}/jq-error"
    if ! decision="$(jq -r "${jq_args[@]}" "${JQ_DECIDE}" "${file}" 2>"${jq_err}")"; then
        emit ERROR pr.evaluate_failed "could not evaluate the PR payload" \
            file="${file}" error="$(error_summary "$(head -3 "${jq_err}" 2>/dev/null || true)")"
        exit_status=1
        return
    fi

    local pr_id="" number="" is_draft="" base_ref="" head_oid="" has_review="" \
        pending="" threads="" unresolved="" reviewed_head="" new_work="" \
        basis="" new_count="" new_oid="" new_date="" last_review_at="" \
        reviewed_oid="" pr_state="" commit_total="" mergeable=""
    IFS=$'\t' read -r pr_id number is_draft base_ref head_oid has_review pending \
        threads unresolved reviewed_head new_work basis new_count new_oid \
        new_date last_review_at reviewed_oid pr_state commit_total \
        mergeable <<<"${decision}"

    ctx_pr="${number}"

    # Only reachable through --pr, which bypasses the OPEN-only list.
    if [[ "${pr_state}" != OPEN ]]; then
        emit INFO pr.skipped "skipped: the pull request is not open" \
            reason=not_open state="${pr_state}"
        return
    fi

    # The full decision record, as attributes: enough to reconstruct any
    # verdict from the log alone without re-querying GitHub.
    emit DEBUG pr.evaluated "evaluated" \
        draft#="$(bool_json "${is_draft}")" \
        base="${base_ref}" head="${head_oid}" \
        has_copilot_review#="$(bool_json "${has_review}")" \
        request_pending#="$(bool_json "${pending}")" \
        copilot_threads#="${threads}" unresolved_threads#="${unresolved}" \
        reviewed_head#="$(bool_json "${reviewed_head}")" \
        reviewed_commit="${reviewed_oid}" last_review_at="${last_review_at}" \
        new_work#="$(bool_json "${new_work}")" basis="${basis}" \
        new_non_merge_count#="${new_count}" commit_total#="${commit_total}" \
        newest_commit="${new_oid}" newest_authored_at="${new_date}" \
        mergeable="${mergeable}"

    marker="$(marker_key "${owner}" "${name}" "${number}")"

    # --- A. mention handling, on every open PR ------------------------------
    # Returns 1 when it filed a request, which settles the PR for this run.
    local mention_rc=0
    handle_mentions "${pr_id}" "${marker}" \
        "${head_oid}" "${reviewed_head}" "${pending}" "${mergeable}" \
        "${file}" || mention_rc=$?
    ((mention_rc == 1)) && return

    # --- B. automatic requests, gated on draft + base branch ----------------
    if [[ "${is_draft}" == 1 ]]; then
        emit DEBUG pr.skipped "skipped: draft" reason=draft
        return
    fi
    # --pr names one PR deliberately, so the base gate does not apply to it: gating
    # would make the flag a silent no-op for any PR off the default branch, which is
    # the opposite of what somebody reaching for it wants.
    if [[ -z "${only_pr}" && "${base_ref}" != "${base}" ]]; then
        other_base_skips=$((other_base_skips + 1))
        emit DEBUG pr.skipped "skipped: does not target the base branch" \
            reason=other_base base="${base_ref}" expected_base="${base}"
        return
    fi
    if [[ -n "${only_pr}" && "${base_ref}" != "${base}" ]]; then
        emit INFO pr.base_gate_bypassed \
            "this PR targets ${base_ref} rather than ${base}, but --pr named it explicitly" \
            base="${base_ref}" expected_base="${base}"
    fi
    if [[ "${pending}" == 1 ]]; then
        emit DEBUG pr.skipped "skipped: a Copilot review request is already pending" \
            reason=request_pending
        return
    fi
    if [[ "${reviewed_head}" == 1 ]]; then
        emit DEBUG pr.skipped "skipped: Copilot already reviewed the head commit" \
            reason=already_reviewed_head head="${head_oid}"
        return
    fi
    if marker_matches "${marker}" "${head_oid}"; then
        emit DEBUG pr.skipped "skipped: already requested for this head commit" \
            reason=already_requested head="${head_oid}"
        return
    fi
    # After the three checks above rather than before them, so this reason means "a
    # request was prevented here" rather than "and it also does not merge". The three of
    # them all say a review already exists or was just asked for, which is the more
    # useful answer when both are true.
    #
    # Tested for MERGEABLE rather than against CONFLICTING, so a request needs GitHub to
    # have positively established that the branch merges. UNKNOWN is not a conflict and
    # is not the author's to fix - see "Conflicts with the base branch" in README.md -
    # but it is treated as one here deliberately. Writing the rule this way also fails
    # closed on any MergeableState value GitHub adds later.
    if [[ "${mergeable}" != MERGEABLE ]]; then
        # Two reasons, not one, because the log must not report a conflict on a PR that
        # has none. A run full of mergeable_unknown is a GitHub problem; a run full of
        # conflicting is a repository problem.
        if [[ "${mergeable}" == CONFLICTING ]]; then
            emit DEBUG pr.skipped "skipped: the branch conflicts with the base branch" \
                reason=conflicting base="${base_ref}" mergeable="${mergeable}"
        else
            emit DEBUG pr.skipped \
                "skipped: GitHub has not established whether the branch merges cleanly" \
                reason=mergeable_unknown base="${base_ref}" mergeable="${mergeable}"
        fi
        return
    fi

    local why="" why_code=""
    if [[ "${has_review}" == 0 ]]; then
        why="no Copilot review yet"
        why_code=never_reviewed
    elif [[ "${unresolved}" != 0 ]]; then
        emit DEBUG pr.skipped "skipped: Copilot threads are still unresolved" \
            reason=unresolved_threads \
            unresolved_threads#="${unresolved}" copilot_threads#="${threads}"
        return
    elif [[ "${new_work}" == 0 ]]; then
        case "${basis}" in
            rewritten)
                emit DEBUG pr.skipped \
                    "skipped: the reviewed commit is not among the commits examined and nothing was authored after it, so this is a restack or an amend rather than new work" \
                    reason=rewritten_without_new_work basis="${basis}" \
                    reviewed_commit="${reviewed_oid}" last_review_at="${last_review_at}" \
                    commit_total#="${commit_total}" \
                    rewrite_triggers_review#="${REWRITE_TRIGGERS_REVIEW}"
                ;;
            *)
                emit DEBUG pr.skipped \
                    "skipped: no non-merge commit added since the review" \
                    reason=no_new_commits basis="${basis}" \
                    reviewed_commit="${reviewed_oid}"
                ;;
        esac
        return
    else
        describe_basis "${basis}" "${threads}" "${new_count}" "${reviewed_oid}" \
            "${new_oid}" "${new_date}" "${last_review_at}" "${commit_total}"
        why="${WHY}"
        why_code="${WHY_CODE}"
    fi

    # The outcome is known before anything is logged, so a deferred PR does not
    # leave a "due for a review" line dangling with no resolution under it. The
    # reason it was due rides along as attributes on whichever outcome event
    # fires, so one event fully describes one decision.
    local rc=0
    request_review "${pr_id}" || rc=$?
    report_request_outcome "${rc}" schedule "${marker}" "${head_oid}" \
        reason="${why_code}" \
        detail="${why}" \
        basis="${basis}" \
        head="${head_oid}" \
        copilot_threads#="${threads}" \
        new_non_merge_count#="${new_count}" \
        commit_total#="${commit_total}" \
        newest_commit="${new_oid}" \
        reviewed_commit="${reviewed_oid}" \
        last_review_at="${last_review_at}" || true
}

# ---------------------------------------------------------------------------
# Per-repo handling
# ---------------------------------------------------------------------------
# One shape for the two early stops that are a budget working as intended: the run
# deadline and the request cap. The read-failure breaker emits reads.halted instead,
# because it is a failure rather than a budget, but it carries the same keys so one
# dashboard reads either. Path-specific extras trail.
report_repo_stopped() { # <message> <reason> <inspected> <total> [attrs...]
    local message="$1" reason="$2" inspected="$3" total="$4"
    shift 4
    local remaining=$((total - inspected))
    ((remaining < 0)) && remaining=0
    emit WARNING repo.stopped "${message}" \
        reason="${reason}" inspected#="${inspected}" total#="${total}" \
        remaining#="${remaining}" "$@"
}

# Takes the owner and the name already split and already shape-checked: that happens
# once at the top level, because the state path is derived from them before this is
# reached.
process_repo() { # <owner> <name>
    local owner="$1" name="$2" base="" page="" cursor="" numbers="" n="" \
        read_class="" remaining=0
    ctx_repo="${owner}/${name}"
    ctx_pr=""

    # Every open PR, however many there are. The list is cheap (100 numbers per
    # call) next to the per-PR query that follows, and a cap here would leave
    # the tail of a busy repo permanently unexamined rather than merely late.
    local pr_numbers=()
    if [[ -n "${only_pr}" ]]; then
        pr_numbers=("${only_pr}")
        base="${base_override:-}"
        if [[ -z "${base}" ]]; then
            if ! page="$(gql "${Q_REPO_PRS}" -f owner="${owner}" -f name="${name}")"; then
                emit ERROR repo.read_failed "cannot read the repository" \
                    error="$(error_summary "$(last_error)")"
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
                    emit ERROR repo.list_failed "cannot list pull requests" \
                        error="$(error_summary "$(last_error)")"
                    diagnose_access "${owner}" "${name}" "$(last_error)"
                    exit_status=1
                    return
                }
            else
                page="$(gql "${Q_REPO_PRS}" -f owner="${owner}" -f name="${name}" -f cursor="${cursor}")" || {
                    emit ERROR repo.list_failed "cannot list pull requests" \
                        error="$(error_summary "$(last_error)")" page=subsequent
                    exit_status=1
                    return
                }
            fi
            # Guarded like has_next below, and for the reason its comment gives: a
            # bare substitution here propagates a jq failure out of the script through
            # the ERR trap, with GitHub's raw output on stderr and no event naming the
            # repository.
            if [[ -z "${base}" ]]; then
                base="${base_override:-$(jq -r '.data.repository.defaultBranchRef.name // ""' <<<"${page}" 2>/dev/null || true)}"
            fi
            if ! numbers="$(jq -r '.data.repository.pullRequests.nodes[]?.number' <<<"${page}" 2>/dev/null)"; then
                emit ERROR repo.list_failed \
                    "the pull request list could not be parsed, so this repository is skipped" \
                    error="unreadable pullRequests payload" page=parse
                exit_status=1
                return
            fi
            for n in ${numbers}; do
                pr_numbers+=("${n}")
            done
            # Tested positively, against both literals: a jq failure, a null or a
            # second document on the stream must not read as "no more pages" and
            # truncate a busy repo silently.
            local has_next
            has_next="$(jq -r '.data.repository.pullRequests.pageInfo.hasNextPage' <<<"${page}" 2>/dev/null || true)"
            case "${has_next}" in
                true)
                    cursor="$(jq -r '.data.repository.pullRequests.pageInfo.endCursor // ""' <<<"${page}" 2>/dev/null || true)"
                    # An empty cursor would send the next iteration down the
                    # first-page branch and page one forever.
                    [[ -n "${cursor}" ]] || {
                        emit ERROR repo.list_failed \
                            "more pull requests follow but no cursor came back, so the list is incomplete; treating it as the end" \
                            error="empty endCursor" page=pagination
                        exit_status=1
                        break
                    }
                    ;;
                false) break ;;
                *)
                    emit ERROR repo.list_failed \
                        "could not tell whether more pull requests follow, so the list may be incomplete; treating it as the end" \
                        error="unexpected hasNextPage: ${has_next:-empty}" page=pagination
                    exit_status=1
                    break
                    ;;
            esac
        done
    fi

    [[ -z "${base}" ]] && {
        emit ERROR repo.no_base_branch "could not determine the base branch"
        exit_status=1
        return
    }

    local total_prs=${#pr_numbers[@]} started=${SECONDS}
    other_base_skips=0
    emit INFO repo.start "inspecting open pull requests" \
        base="${base}" open_prs#="${total_prs}"

    # The deployment budgeted the GraphQL quota at EXPECTED_OPEN_PRS, and reads are most of
    # what a run spends, so a repository that has outgrown that figure spends more than the
    # fleet was sized for. Said once per run, at WARNING, because it is the only moment
    # anything holds both numbers: the declared one comes from jobs.json, which the bot never
    # reads, and the true one is not known until the list has been paged. Only under-declaring
    # matters, so an over-declaration is silent.
    if [[ -n "${EXPECTED_OPEN_PRS}" ]] && ((total_prs > EXPECTED_OPEN_PRS)); then
        emit WARNING repo.more_prs_than_expected \
            "this repository has ${total_prs} open pull requests, past the ${EXPECTED_OPEN_PRS} the deployment budgets the API quota at, so the fleet is spending more than it was sized for" \
            open_prs#="${total_prs}" expected_open_prs#="${EXPECTED_OPEN_PRS}" \
            over_by#="$((total_prs - EXPECTED_OPEN_PRS))" \
            remedy=raise_expected_open_prs
    fi

    # Each PR is decided as soon as it is fetched, so output starts immediately
    # rather than after the last fetch. Nothing has to be learned from the repo
    # first: gh resolves the reviewer at request time, so there is no id to
    # discover and no reason to defer a decision.
    #
    # Deliberately unguarded: inside a fresh mktemp -d, this fails only if the
    # filesystem is full or read-only, and there is no useful local recovery from
    # that. The ERR trap is its handler, which is what `set -E` is for - it reports
    # run.aborted and the exit trap still frees the lock.
    local dir="${TMPDIR_RUN}/${owner}-${name}" out="" file="" idx=0
    mkdir -p "${dir}"

    for n in "${pr_numbers[@]}"; do
        # Stopping on our own terms beats being killed by the platform: a
        # SIGKILL mid-run costs the lock for the rest of its TTL, which is two
        # further ticks, on top of this one.
        if run_deadline_reached; then
            stop_scanning=true
            stop_reason=run_deadline
            report_repo_stopped \
                "stopping early: the run deadline of ${RUN_DEADLINE_SECONDS}s is reached, so the remaining PRs are left to the next run" \
                run_deadline "${idx}" "${total_prs}" \
                deadline_seconds#="${RUN_DEADLINE_SECONDS}" \
                elapsed_seconds#="${SECONDS}"
            break
        fi

        idx=$((idx + 1))
        ctx_pr="${n}"
        emit DEBUG pr.fetching "fetching" index#="${idx}" total#="${total_prs}"
        ctx_pr=""

        file="${dir}/pr-${n}.json"
        # Counted here rather than inside gql(), which runs in a $( ) subshell
        # where any variable it sets is discarded on return.
        if ! out="$(gql "${Q_PR}" -f owner="${owner}" -f name="${name}" -F number="${n}")"; then
            consecutive_read_failures=$((consecutive_read_failures + 1))
            read_class="$(classify_failure "$(last_error)")"
            ctx_pr="${n}"
            # Classified like a failed request, and for the same reason: the exit
            # status is documented to mean "a PR hit a permanent error", so one 502 in
            # a sweep of hundreds must not make the whole execution report failure.
            # The breaker below is what turns a run of them into a loud one.
            if [[ "${read_class}" == transient ]]; then
                transients=$((transients + 1))
                emit WARNING pr.read_failed \
                    "transient failure reading the pull request, will retry on the next run" \
                    error="$(error_summary "$(last_error)")" \
                    failure_class=transient retryable#=true \
                    consecutive_read_failures#="${consecutive_read_failures}"
                [[ "${TRANSIENT_FAILURES_ARE_ERRORS}" == true ]] && exit_status=1
            else
                emit ERROR pr.read_failed "cannot read the pull request" \
                    error="$(error_summary "$(last_error)")" \
                    failure_class=permanent retryable#=false \
                    consecutive_read_failures#="${consecutive_read_failures}"
                exit_status=1
            fi
            ctx_pr=""
            # Each failed read has already cost three attempts and nine seconds
            # of sleeping. Walking a whole repo that way outlasts any sane task
            # timeout, so a degraded GitHub ends the sweep instead.
            if ((consecutive_read_failures >= MAX_CONSECUTIVE_READ_FAILURES)); then
                stop_scanning=true
                stop_reason=read_failures
                # ERROR and exit 1 whatever the class of the individual failures.
                # Abandoning the sweep means work the run was asked to do was not
                # done, which somebody should see even when every cause was a blip.
                exit_status=1
                remaining=$((total_prs - idx))
                ((remaining < 0)) && remaining=0
                # Its own event rather than repo.stopped, because this is the only
                # early stop that is an error rather than a budget working as
                # intended. It carries repo.stopped's key set so one dashboard can
                # read either.
                emit ERROR reads.halted \
                    "stopping the sweep after consecutive read failures; GitHub looks unhealthy, so the remaining PRs are left to the next run" \
                    reason=read_failures \
                    consecutive_read_failures#="${consecutive_read_failures}" \
                    threshold#="${MAX_CONSECUTIVE_READ_FAILURES}" \
                    inspected#="${idx}" total#="${total_prs}" \
                    remaining#="${remaining}"
                break
            fi
            continue
        fi
        # One pass, not two: `jq -ce` exits 1 when its output is null, so the
        # extraction and the "does this PR exist" check are the same call. -c
        # because the file is only ever read back by jq, and pretty-printing it
        # doubles what Cloud Run's in-memory filesystem has to hold.
        if ! jq -ce '.data.repository.pullRequest' <<<"${out}" >"${file}" 2>/dev/null; then
            ctx_pr="${n}"
            # Names what was observed, not a cause. The same guard fires for a PR that
            # is gone, for a repository renamed or deleted mid-sweep, and for any
            # response that is not the expected shape. During a sweep the numbers come
            # from the list call moments earlier, so "no such PR" is the least likely
            # of the three.
            emit ERROR pr.read_unexpected \
                "the response carried no pullRequest object: the PR is gone, or the repository was renamed mid-run" \
                reason=no_pull_request_in_payload \
                repository_present#="$(jq -c 'if .data.repository == null then false else true end' <<<"${out}" 2>/dev/null || printf null)"
            ctx_pr=""
            exit_status=1
            continue
        fi
        consecutive_read_failures=0
        decide_pr "${owner}" "${name}" "${base}" "${file}"

        # Once the budget is gone there is nothing left to do with the
        # remaining PRs but fetch them and defer them, at one API call each, so
        # stop and let the next run start from the top. Ordering is by recent
        # activity, and a PR that gets its request drops out of contention on
        # the following run, so a backlog drains rather than starving the tail.
        if requests_exhausted; then
            stop_scanning=true
            if ((total_prs - idx > 0)); then
                report_repo_stopped "stopping early: $(budget_reason)" \
                    "$(budget_reason_code)" "${idx}" "${total_prs}" \
                    limit#="${MAX_REQUESTS_PER_RUN}"
            fi
            break
        fi

        # A heartbeat for non-verbose runs, which are otherwise silent for every
        # PR that needs no action.
        if [[ "${verbose}" != true ]] && ((PROGRESS_EVERY > 0)) &&
            ((idx % PROGRESS_EVERY == 0)) && ((idx < total_prs)); then
            emit INFO repo.progress "still going" \
                inspected#="${idx}" total#="${total_prs}" \
                elapsed_seconds#="$((SECONDS - started))"
        fi
    done

    requests_exhausted && stop_scanning=true
    ctx_pr=""
    emit INFO repo.done "finished with this repository" \
        inspected#="${idx}" total#="${total_prs}" \
        duration_seconds#="$((SECONDS - started))"
    # Every PR skipped for the base branch means --base names something no PR
    # targets, which otherwise looks exactly like a healthy run with nothing to do
    # and is invisible without --verbose.
    if ((idx > 0 && other_base_skips == idx)); then
        emit WARNING repo.no_matching_base \
            "every open pull request targets a different branch, so nothing can ever be requested here; check the --base value" \
            reason=base_matches_nothing expected_base="${base}" \
            inspected#="${idx}"
    fi
    ctx_repo=""
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
# Every external command the script runs is checked up front, coreutils included: a
# missing one discovered mid-run produces a raw non-JSON line and a fatal that names
# the wrong cause. `flock` matters most, because "command not found" is exit 127,
# which is indistinguishable from "the lock is held" unless it is checked, so a
# missing flock would turn every run into a silent no-op.

# Package suggestions, tailored to whatever this machine looks like.
install_hint() { # <binary>
    local os
    os="$(uname -s 2>/dev/null || echo unknown)"
    case "$1:${os}" in
        gh:Darwin) echo "brew install gh" ;;
        gh:*) echo "see https://github.com/cli/cli#installation" ;;
        jq:Darwin) echo "brew install jq" ;;
        jq:*) echo "apt-get install jq  (or dnf install jq)" ;;
        curl:Darwin) echo "brew install curl" ;;
        curl:*) echo "apt-get install curl  (or dnf install curl)" ;;
        flock:Darwin) echo "brew install flock" ;;
        flock:*) echo "apt-get install util-linux  (or dnf install util-linux)" ;;
        bash:Darwin) echo "brew install bash, then run the script with that bash" ;;
        bash:*) echo "apt-get install bash" ;;
        *) echo "install $1 and make sure it is on PATH" ;;
    esac
}

require_binaries() { # <binary>...
    local b missing=()
    for b in "$@"; do
        command -v "${b}" >/dev/null 2>&1 || missing+=("${b}")
    done
    if ((${#missing[@]} > 0)); then
        emit ERROR run.fatal "missing required program(s): ${missing[*]}" \
            reason=missing_prerequisites missing="${missing[*]}"
        for b in "${missing[@]}"; do
            emit ERROR run.prerequisite_missing "${b} - $(install_hint "${b}")" \
                program="${b}" hint="$(install_hint "${b}")"
        done
        exit 2
    fi
}

# timeout(1) is in coreutils, which the runtime image has. A machine without it
# still runs, just without the guard, so this warns rather than refusing.
detect_gh_timeout() {
    ((GH_TIMEOUT == 0)) && return 0
    local t
    for t in timeout gtimeout; do
        if command -v "${t}" >/dev/null 2>&1; then
            GH_TIMEOUT_PREFIX=("${t}" "${GH_TIMEOUT}")
            return 0
        fi
    done
    emit WARNING run.no_gh_timeout \
        "neither timeout nor gtimeout is on PATH, so gh calls are unbounded and a hung connection will stall this run until the platform kills it" \
        remedy=install_coreutils
    return 0
}

# GNU and BSD date disagree about relative dates, and this runs on Linux but
# gets tested on macOS. Probe once, then go through date_days_ago() and
# date_minutes_ago().
DATE_FLAVOR=""
detect_date_flavor() {
    if date -u -d "1 day ago" +%Y >/dev/null 2>&1; then
        DATE_FLAVOR=gnu
    elif date -u -v-1d +%Y >/dev/null 2>&1; then
        DATE_FLAVOR=bsd
    else
        emit ERROR run.fatal \
            "cannot compute relative dates with this 'date' implementation (neither 'date -d' nor 'date -v' works)" \
            reason=unusable_date
        exit 2
    fi
}

# RFC 3339, that many days or minutes before now. One function for both, because the
# two differed only in the unit word and the BSD suffix - and the suffixes are
# case-sensitive in a way that is easy to get wrong: -v-1d is a day, -v-1M is a minute
# and -v-1m is a month.
date_ago() { # <count> <days|minutes>
    local n="$1" unit="$2"
    case "${DATE_FLAVOR}:${unit}" in
        gnu:*) date -u -d "${n} ${unit} ago" +%Y-%m-%dT%H:%M:%SZ ;;
        bsd:days) date -u -v-"${n}"d +%Y-%m-%dT%H:%M:%SZ ;;
        bsd:minutes) date -u -v-"${n}"M +%Y-%m-%dT%H:%M:%SZ ;;
        *)
            emit ERROR run.fatal \
                "date_ago called with unit '${unit}' before detect_date_flavor" \
                reason=internal
            exit 2
            ;;
    esac
}

date_days_ago() { # <days>
    date_ago "$1" days
}

date_minutes_ago() { # <minutes>
    date_ago "$1" minutes
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Debug shortcut: evaluate a saved pullRequest object and print the outcome.
if [[ -n "${explain_file}" ]]; then
    require_binaries jq
    parse_copilot_logins
    viewer="${VIEWER_LOGIN:-xrplf-bot}"
    MENTION_SINCE="${MENTION_SINCE:-1970-01-01T00:00:00Z}"
    printf 'id\tnumber\tdraft\tbase\thead\thas_review\tpending\tthreads\tunresolved\treviewed_head\tnew_work\tbasis\tnew_count\tnew_oid\tnew_date\tlast_review\treviewed_oid\tstate\tcommit_total\tmergeable\n'
    jq -r "${jq_args[@]}" "${JQ_DECIDE}" "${explain_file}"
    printf -- '--- mentions (id, kind, createdAt, author) ---\n'
    jq -r "${jq_args[@]}" --arg viewer "${viewer}" --arg since "${MENTION_SINCE}" \
        "${JQ_MENTIONS}" "${explain_file}"
    exit 0
fi

# The repository, resolved before anything else, because the state and lock paths are
# derived from it: the command line, else ${REPO}.
[[ -z "${repo}" ]] && repo="${REPO:-}"
# The event first, then the help. Every other exit-2 path emits run.fatal, and a bare
# help dump carries no severity, no event and no time, so the runbook's filters and the
# ERROR-severity metric both miss the one line that reports the failure.
[[ -z "${repo}" ]] && {
    emit ERROR run.fatal \
        "no repository given: use --repo owner/name, or set REPO" \
        reason=no_repos
    usage 2
}
# Shape-checked before the split, so "/rippled" and "XRPLF/" - one slash each, and so
# past a slash count - cannot reach GitHub as an empty owner or name. Fatal rather than
# a per-repo skip: one process watches one repository, so there is nothing left to fall
# back to and this is the same class of mistake as naming none at all.
[[ "${repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
    emit ERROR run.fatal "invalid repository '${repo}', expected owner/name" \
        reason=bad_repo given="${repo}"
    exit 2
}
owner="${repo%%/*}"
name="${repo##*/}"

parse_state_dir "${owner}" "${name}"
if [[ "${STATE_IS_GCS}" == true ]]; then
    require_binaries gh jq curl mktemp sed grep tr head tail cat cp mv rm dirname uname
else
    require_binaries gh jq flock mktemp sed grep tr head tail cat cp mv rm dirname uname
fi
# Checked after require_binaries, because it needs jq: an invalid value would
# otherwise fail every per-PR evaluation instead of being reported once, here.
parse_copilot_logins
detect_date_flavor
detect_gh_timeout

if [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]] && ! gh auth status >/dev/null 2>&1; then
    emit ERROR run.fatal \
        "no GitHub credentials: set GH_TOKEN/GITHUB_TOKEN or run 'gh auth login'" \
        reason=no_credentials
    exit 2
fi

TMPDIR_RUN="$(mktemp -d)"
ERR_FILE="${TMPDIR_RUN}/last-error"

# Everything below is reached only through the traps, never called directly.
# shellcheck disable=SC2329
cleanup() {
    # The lock goes first, deliberately. A platform shutting this run down gives
    # the trap a few seconds, and the two jobs are not equally urgent: losing a
    # marker costs one wasted API call on the next run, whereas an unreleased
    # lock makes the next tick a no-op and is only cleared after
    # LOCK_TTL_MINUTES. So the contended resource is freed while there is still
    # time, and both calls are shortened to fit the window rather than the
    # ordinary per-call timeouts.
    GCS_HTTP_TIMEOUT="${CLEANUP_HTTP_TIMEOUT}"
    GCS_TOKEN_TIMEOUT="${CLEANUP_HTTP_TIMEOUT}"
    GCS_MAX_ATTEMPTS=1
    release_lock || true
    state_save || true
    rm -rf "${TMPDIR_RUN}"
}

# Without these, an aborted run is indistinguishable from one that never
# started: the log simply stops after the last PR, with no terminal event to
# alert on. Both re-raise through exit, so cleanup still runs.
# shellcheck disable=SC2329
on_signal() { # <name> <status>
    emit ERROR run.aborted \
        "the run was terminated by ${1} before it finished; the remaining PRs are left to the next run" \
        reason=signal signal="${1}" \
        requests_filed#="${requests_made}" duration_seconds#="${SECONDS}"
    exit "$2"
}

# Exits 2 rather than letting the failing command's own status through: an
# unexpected internal error is a fatal, and 1 is documented to mean "a PR hit a
# permanent error", which alerting has to be able to tell apart.
# shellcheck disable=SC2329
on_error() { # <line>
    # `set -E` inherits this trap into every $( ) subshell, so a failure inside one
    # fires it there and then again in the parent when the assignment fails. Only the
    # process that owns the run reports; the subshell just exits.
    [[ "${BASHPID:-$$}" == "$$" ]] || exit 2
    emit ERROR run.aborted \
        "the run stopped on an unexpected error and did not finish" \
        reason=unexpected_error line#="${1}" \
        requests_filed#="${requests_made}" duration_seconds#="${SECONDS}"
    exit 2
}

trap cleanup EXIT
trap 'on_signal SIGTERM 143' TERM
trap 'on_signal SIGINT 130' INT
trap 'on_error "${LINENO}"' ERR

if [[ "${STATE_IS_GCS}" == true ]]; then
    gcs_auth_refresh || exit 2
fi

lock_rc=0
acquire_lock || lock_rc=$?
case "${lock_rc}" in
    0) ;;
    1) exit 0 ;; # held by a live run, and that is not an error
    *) exit 2 ;;
esac

MENTION_SINCE="$(date_days_ago "${MENTION_MAX_AGE_DAYS}")"

# Through gql(), so the first GitHub call of the run gets the same retry as every
# other read. A 502 here is a blip, not a bad token, and reporting it as one sent
# people to check a credential that was fine.
if ! viewer="$(gql '{ viewer { login } }' --jq .data.viewer.login)"; then
    viewer_error="$(error_summary "$(last_error)")"
    emit ERROR run.fatal \
        "cannot identify the authenticated account: ${viewer_error}" \
        reason=viewer_unknown error="${viewer_error}" \
        failure_class="$(classify_failure "$(last_error)")"
    exit 2
fi
if [[ -z "${viewer}" ]]; then
    emit ERROR run.fatal \
        "the API answered but named no login for this token; check that it is not a fine-grained token with no account scope" \
        reason=viewer_unknown
    exit 2
fi

state_load
warn_if_state_is_ephemeral

emit INFO run.start "copilot-review-bot starting" \
    version="${VERSION}" viewer="${viewer}" dry_run#="${dry_run}" \
    reviewer="${REVIEWER}" reviewer_field="${REVIEWER_FIELD}" \
    handle="${MENTION_HANDLE}" mention_since="${MENTION_SINCE}" \
    repo="${owner}/${name}" max_requests#="${MAX_REQUESTS_PER_RUN}" \
    rewrite_triggers_review#="${REWRITE_TRIGGERS_REVIEW}" \
    state_dir="${STATE_DIR}" \
    state_backend="$(state_backend_name)"

process_repo "${owner}" "${name}"

# Explicitly here, rather than only in the exit trap, so that a failure to store
# the markers is reflected in the exit status instead of arriving after it.
state_save || true

# A dry run walks every PR, because the request cap never moves for it (see
# requests_exhausted), so would_request is the whole outstanding backlog rather than a
# prediction of the next run. This is the part of that backlog a real run would actually
# file before the cap stopped it, which is the number somebody reading a dry run is
# usually after. Reported alongside rather than instead of the total: the total answers
# "how far behind are we", and this answers "what happens next tick".
would_next=$((would_request < MAX_REQUESTS_PER_RUN ? would_request : MAX_REQUESTS_PER_RUN))

# The message has to agree with the severity: a run that is about to be logged at
# ERROR must not open with the word "done".
if [[ "${dry_run}" == true ]]; then
    summary="done: ${would_request} review request(s) would be filed"
    # Only when the two differ. "25 would be filed, 25 of them on the next run" is noise.
    ((would_request > MAX_REQUESTS_PER_RUN)) &&
        summary+=", ${would_next} of them on the next run"
elif ((exit_status != 0)); then
    summary="finished with errors: ${requests_made} review request(s) filed"
else
    summary="done: ${requests_made} review request(s) filed"
fi
((deferrals > 0)) && summary+=", ${deferrals} deferred to the next run"
((transients > 0)) && summary+=", ${transients} transient failure(s) to retry"
[[ "${requests_halted}" == true ]] && summary+=", requests halted early ($(budget_reason_code))"
# A run that stopped short always says why.
[[ "${stop_scanning}" == true && "${requests_halted}" != true ]] &&
    summary+=", stopped early ($(budget_reason))"

emit "$(if ((exit_status != 0)); then printf ERROR; else printf INFO; fi)" \
    run.done "${summary}" \
    requests_filed#="${requests_made}" requests_attempted#="${request_attempts}" \
    would_file#="${would_request}" would_file_next_run#="${would_next}" \
    deferred#="${deferrals}" transient_failures#="${transients}" \
    mention_writes#="${mention_writes}" \
    requests_halted#="${requests_halted}" halt_reason="${halt_reason:-none}" \
    deadline_reached#="${deadline_hit}" \
    stopped_early#="${stop_scanning}" \
    stop_reason="$(if [[ "${stop_scanning}" == true ]]; then stop_reason_code; else printf none; fi)" \
    dry_run#="${dry_run}" \
    duration_seconds#="${SECONDS}" exit_status#="${exit_status}"
exit "${exit_status}"

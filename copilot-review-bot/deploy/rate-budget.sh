#!/usr/bin/env bash
#
# rate-budget.sh - validate jobs.json, and refuse a deployment that cannot fit in
# GitHub's hourly GraphQL quota.
#
# Two jobs in one script, because both need every entry at once and both have to run
# before anything is built. deploy-job.sh sees a single entry, so it cannot check
# uniqueness, and it runs after the image is pushed, so a refusal there costs a
# registry write and a half-reconciled fleet.
#
# It also derives what jobs.json no longer states: the Cloud Run job name, from `repo`, and
# the tick schedule, from `ticks_per_hour` and an offset. Both derivations live in
# job-config.sh, which deploy-job.sh sources too, because a fleet this check charges for has
# to be the fleet that then gets deployed.
#
# The quota is 5000 points per hour and it is per *account*, not per token, per job,
# per repo or per schedule. Every token issued for one account draws on that single
# budget, so a second token for the same account buys nothing. Every Cloud Run job uses
# the same gh-token, so adding a repo spends somebody else's budget. Reads then start
# failing part way through a run: each one is
# an ERROR `pr.read_failed`, and after MAX_CONSECUTIVE_READ_FAILURES in a row the run
# stops with `reason=read_failures`, leaving the remaining pull requests for the next
# run. Nothing about one job's own configuration reveals that it is the cause.
#
# Costs, measured against XRPLF/rippled with `rateLimit { cost }` rather than assumed,
# because GitHub's cost is not derivable from the node count: a shape with 304 nodes
# costs 2 and one with 1984 nodes costs 1.
#
#   Q_REPO_PRS (100 PR numbers)   1 point
#   Q_PR       (one PR, in full)  2 points
#   { viewer { login } }          1 point, once per run
#
# The review request is one requestReviewsByLogin mutation, so it is almost certainly
# 1 point, but it has never been measured: measuring it means filing a real review
# request. It stays charged at 3, which is what it cost while the bot ran `gh pr edit`
# and paid for a PR lookup as well. Left high on purpose - the whole model is an upper
# bound, and unmeasured headroom is worth more here than a tighter number.
#
# A mention write (addReaction or addComment) is one mutation, charged at 1 and
# counted at the bot's own MAX_MENTION_WRITES_PER_RUN cap. Charging the cap rather
# than an estimate keeps this an upper bound.
#
# Usage: ./rate-budget.sh [path-to-jobs.json]
#
set -Eeuo pipefail

SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=job-config.sh
. "${SUITE_DIR}/job-config.sh"
JOBS="${1:-${SUITE_DIR}/jobs.json}"

# GitHub's hourly GraphQL quota for one account.
QUOTA="${QUOTA:-5000}"
# Warn here rather than at the ceiling. A deployment that lands at 99% is one busy
# week away from dropping PRs, and the lead time on the remedy (lengthening a
# schedule, or a token for a second account) is longer than that.
WARN_PERCENT="${WARN_PERCENT:-80}"

POINTS_LIST_CALL=1
POINTS_PER_PR=2
POINTS_PER_REQUEST=3
POINTS_PER_MENTION_WRITE=1
POINTS_VIEWER_QUERY=1

# Defaults for the optional fields, in one place. deploy-job.sh reads the same keys
# and defaults them the same way; the required fields below are what stop the two
# drifting on anything that matters.
DEFAULT_MENTION_WRITES=50
DEFAULT_TASK_TIMEOUT=20m
DEFAULT_LOCK_TTL_MINUTES=25
DEFAULT_RUN_DEADLINE_SECONDS=900

command -v jq >/dev/null || {
    echo "jq is required" >&2
    exit 2
}
[[ -r "${JOBS}" ]] || {
    echo "cannot read ${JOBS}" >&2
    exit 2
}
jq -e . "${JOBS}" >/dev/null 2>&1 || {
    echo "${JOBS} is not valid JSON" >&2
    exit 2
}

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------
# One jq program for everything structural, so there is a single statement of what a
# jobs.json entry is. Each rule is reported by name, because "jobs.json is invalid" on
# its own sends the reader back to guess which of ten fields is wrong.
#
# `name` must carry the copilot-review-bot prefix because every alert filter in
# deploy/README.md is a prefix match on the job name, so a differently named job would
# deploy, tick, file real review requests and be invisible to all four metrics.
#
# `@` is excluded from every string because deploy-job.sh joins the environment with
# `^@^`, where the delimiter may not appear in any value.
schema_errors="$(jq -r '
    def bad($why): "  " + $why;
    def is_uint: type == "number" and . == floor and . >= 0;
    # gcloud --task-timeout: seconds, or a number suffixed s, m or h. Mirrors what
    # duration_seconds() below actually parses, so a value this accepts never fails
    # there with a raw, unstructured error instead of a named schema one.
    def is_duration: type == "string" and test("^[0-9]+[smh]?$");
    # gcloud --memory: a whole number suffixed Mi, Gi, M or G. Cloud Run also accepts
    # other Kubernetes quantity suffixes, but every job here uses one of these four, so
    # anything else is far more likely a typo than a value worth accepting.
    def is_memory: type == "string" and test("^[0-9]+(Mi|Gi|M|G)$");

    (.jobs // null) as $jobs
    | if ($jobs | type) != "array" then [bad("jobs must be an array")]
      elif ($jobs | length) == 0 then [bad("jobs lists no jobs")]
      else
        [ ($jobs | to_entries[] | .key as $i | .value as $j
           | [ # name is optional, and derived from repo when it is absent. An explicit one
               # exists only for what the derivation cannot serve - a pair too long for
               # Cloud Run, or two repositories that fold to one name - so it still has to
               # carry the prefix every alert filter matches on.
               (if ($j | has("name")) and (($j.name | type) != "string" or ($j.name == ""))
                then bad("jobs[\($i)].name, when given, must be a non-empty string") else empty end),
               (if ($j | has("name")) and (($j.name | type) == "string") and ($j.name | startswith("copilot-review-bot") | not)
                then bad("jobs[\($i)].name must start with copilot-review-bot, so the alert filters match it") else empty end),
               (if ($j.repo? | type) != "string" or ($j.repo | test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$") | not)
                then bad("jobs[\($i)].repo must be owner/name") else empty end),
               # A count rather than a cron. Only the minute field was ever used, because a
               # job that is not hourly cannot be budgeted per hour, and `*/N` then had to
               # be turned back into a count by ceiling division. Stating the count removes
               # both the parser and the arithmetic.
               (if ($j.ticks_per_hour? | is_uint | not)
                then bad("jobs[\($i)].ticks_per_hour must be a whole number") else empty end),
               # Only these give evenly spaced ticks. Refused rather than spaced unevenly,
               # because uneven is almost never what somebody meant and the remedy is to
               # pick a neighbouring count.
               (if ($j.ticks_per_hour? | is_uint) and ([1,2,3,4,5,6,10,12,15,20,30,60] | index($j.ticks_per_hour) == null)
                then bad("jobs[\($i)].ticks_per_hour must divide 60 evenly: one of 1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30, 60") else empty end),
               (if ($j | has("offset_minutes")) and (($j.offset_minutes | is_uint | not) or ($j.offset_minutes > 59))
                then bad("jobs[\($i)].offset_minutes must be a whole number of minutes past the hour, 0 to 59") else empty end),
               (if ($j.expected_open_prs? | is_uint | not)
                then bad("jobs[\($i)].expected_open_prs must be a whole number") else empty end),
               (if ($j.max_requests_per_run? | is_uint | not)
                then bad("jobs[\($i)].max_requests_per_run must be a whole number, and is required so it cannot differ from what this check budgets") else empty end),
               (if ($j | has("max_mention_writes_per_run")) and ($j.max_mention_writes_per_run | is_uint | not)
                then bad("jobs[\($i)].max_mention_writes_per_run must be a whole number") else empty end),
               (if ($j | has("lock_ttl_minutes")) and ($j.lock_ttl_minutes | is_uint | not)
                then bad("jobs[\($i)].lock_ttl_minutes must be a whole number") else empty end),
               (if ($j | has("run_deadline_seconds")) and ($j.run_deadline_seconds | is_uint | not)
                then bad("jobs[\($i)].run_deadline_seconds must be a whole number") else empty end),
               (if ($j | has("dry_run")) and (($j.dry_run | type) != "boolean")
                then bad("jobs[\($i)].dry_run must be true or false") else empty end),
               (if ($j | has("verbose")) and (($j.verbose | type) != "boolean")
                then bad("jobs[\($i)].verbose must be true or false") else empty end),
               (if ($j | has("task_timeout")) and ($j.task_timeout | is_duration | not)
                then bad("jobs[\($i)].task_timeout must be a number of seconds, optionally suffixed s, m or h") else empty end),
               (if ($j | has("memory")) and ($j.memory | is_memory | not)
                then bad("jobs[\($i)].memory must be a whole number suffixed Mi, Gi, M or G") else empty end),
               ($j | to_entries[] | select((.value | type) == "string" and (.value | contains("@")))
                | bad("jobs[\($i)].\(.key) must not contain @, which deploy-job.sh uses as its environment delimiter")) ]
           | .[] ),
          # Job-name uniqueness is checked below rather than here, because the name is
          # usually derived and jq is not the thing that derives it.
          (if ([$jobs[].repo] | unique | length) != ($jobs | length)
           then bad("repo values must be unique: the state path is derived from the repository, so two jobs watching one repo share its lock object and one is starved every tick") else empty end) ]
      end
    | .[]' "${JOBS}")"

if [[ -n "${schema_errors}" ]]; then
    printf '%s is not a valid job list:\n%s\n' "${JOBS}" "${schema_errors}" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Schedules and timeouts
# ---------------------------------------------------------------------------
# Every job's Cloud Run name, derived unless the entry declares one, checked as a set.
#
# Three ways a name can be wrong, and none of them is visible in a single entry, which is
# why this runs here rather than in deploy-job.sh: too long for Cloud Run, two repositories
# folding to one name, or a declared name colliding with a derived one.
check_job_names() { # -> 0 if every name is usable and unique
    local i repo name errs="" seen=""
    for ((i = 0; i < count; i++)); do
        repo="$(field "${i}" repo)"
        name="$(field "${i}" name)"
        [[ -n "${name}" ]] || name="$(job_name_for "${repo}")"
        if ((${#name} > JOB_NAME_MAX_LENGTH)); then
            errs+="  job for ${repo}: the name '${name}' is ${#name} characters, over the Cloud Run limit of ${JOB_NAME_MAX_LENGTH}; set \"name\" explicitly to something shorter"$'\n'
        fi
        if [[ "${name}" != "${JOB_NAME_PREFIX}"* ]]; then
            errs+="  job for ${repo}: the name '${name}' does not start with ${JOB_NAME_PREFIX}, so no alert filter would match it"$'\n'
        fi
        case " ${seen} " in
            *" ${name} "*)
                errs+="  job for ${repo}: the name '${name}' is already taken by another entry; set \"name\" explicitly on one of them"$'\n'
                ;;
        esac
        seen+="${name} "
    done
    [[ -z "${errs}" ]] && return 0
    printf '%s is not a valid job list:\n%s' "${JOBS}" "${errs}" >&2
    return 1
}

# gcloud accepts a bare number of seconds or a unit suffix. Normalised here so the
# three timeouts can be compared against each other.
duration_seconds() { # <duration> -> seconds on stdout, 1 if unparseable
    local d="$1" n="${1%[smh]}"
    [[ "${n}" =~ ^[0-9]+$ ]] || {
        echo "unparseable duration '${d}'" >&2
        return 1
    }
    case "${d}" in
        *h) printf '%s' $((n * 3600)) ;;
        *m) printf '%s' $((n * 60)) ;;
        *s | *[0-9]) printf '%s' "${n}" ;;
        *)
            echo "unparseable duration '${d}'" >&2
            return 1
            ;;
    esac
}

# The bot has to stop on its own terms before the platform kills it, and the lock has
# to outlive a killed task only briefly. A task killed by its timeout runs no trap, so
# it releases nothing: the lock then blocks the schedule until its TTL expires.
check_timeout_order() { # <name> <deadline-s> <task-timeout> <lock-ttl-min>
    local name="$1" deadline="$2" task="$3" ttl_min="$4" task_s ttl_s
    task_s="$(duration_seconds "${task}")" || return 1
    ttl_s=$((ttl_min * 60))
    if ((deadline >= task_s)); then
        echo "job '${name}': run_deadline_seconds (${deadline}) must be below task_timeout (${task}, ${task_s}s), or the platform kills the run before it can stop cleanly" >&2
        return 1
    fi
    if ((task_s >= ttl_s)); then
        echo "job '${name}': task_timeout (${task}, ${task_s}s) must be below lock_ttl_minutes (${ttl_min}, ${ttl_s}s), or a slow but healthy run has its lock broken under it" >&2
        return 1
    fi
    return 0
}

total=0
rows=()
machine=()
count="$(jq '.jobs | length' "${JOBS}")"

# One entry's field, with a default for the optional ones. `has`, not jq's `//`:
# `false // "x"` is "x", because jq counts false as empty, so `//` would quietly turn
# a "verbose": false into the default of true. Same helper and same reasoning as
# deploy-job.sh, so the two readers of this file agree on what a field means.
field() { # <index> <key> [default]
    jq -r --argjson i "$1" --arg k "$2" --arg d "${3-}" \
        '.jobs[$i] | if has($k) and .[$k] != null then .[$k] else $d end' "${JOBS}"
}

# Needs both `field` and `count`, so it runs here rather than beside the jq schema. Exit 2
# like every other configuration error.
check_job_names || exit 2

for ((i = 0; i < count; i++)); do
    repo="$(field "${i}" repo)"
    name="$(field "${i}" name)"
    [[ -n "${name}" ]] || name="$(job_name_for "${repo}")"
    per_hour="$(field "${i}" ticks_per_hour)"
    offset="$(field "${i}" offset_minutes)"
    [[ -n "${offset}" ]] || offset="$(offset_for "${repo}" $((60 / per_hour)))"
    schedule="$(schedule_for "${per_hour}" "${offset}")"
    prs="$(field "${i}" expected_open_prs)"
    reqs="$(field "${i}" max_requests_per_run)"
    mentions="$(field "${i}" max_mention_writes_per_run "${DEFAULT_MENTION_WRITES}")"
    ttl="$(field "${i}" lock_ttl_minutes "${DEFAULT_LOCK_TTL_MINUTES}")"
    deadline="$(field "${i}" run_deadline_seconds "${DEFAULT_RUN_DEADLINE_SECONDS}")"
    task_timeout="$(field "${i}" task_timeout "${DEFAULT_TASK_TIMEOUT}")"

    # Exit 2, the config-error code, rather than letting set -e make it 1: a timeout
    # ordering mistake is the same class as a missing field.
    check_timeout_order "${name}" "${deadline}" "${task_timeout}" "${ttl}" || exit 2

    # Ceiling division: 267 PRs is three list calls, not two.
    list_calls=$(((prs + 99) / 100))
    per_run=$((POINTS_VIEWER_QUERY + list_calls * POINTS_LIST_CALL + prs * POINTS_PER_PR + \
        reqs * POINTS_PER_REQUEST + mentions * POINTS_PER_MENTION_WRITE))
    hourly=$((per_run * per_hour))
    total=$((total + hourly))

    rows+=("$(printf '%-40s %-24s %-20s %6s %8s %9s' \
        "${name}" "${repo}" "${schedule}" "${per_hour}" "${per_run}" "${hourly}")")
    # A second, machine-readable line per job. The suite asserts on these rather than
    # on the table's column spacing, so re-formatting the table breaks nothing.
    machine+=("$(printf 'budget\t%s\t%s\t%s\t%s' \
        "${name}" "${per_hour}" "${per_run}" "${hourly}")")
done

printf '%-40s %-24s %-20s %6s %8s %9s\n' JOB REPO SCHEDULE RUNS/H PTS/RUN PTS/H
printf '%s\n' "${rows[@]}"
printf '%-40s %-24s %-20s %6s %8s %9s\n' TOTAL "" "" "" "" "${total}"
printf '%s\n' "${machine[@]}"
printf 'budget\tTOTAL\t\t\t%s\n' "${total}"
printf '\nquota %s points/hour per account, used %s (%s%%)\n' \
    "${QUOTA}" "${total}" "$((total * 100 / QUOTA))"

if ((total >= QUOTA)); then
    cat >&2 <<EOF

REFUSING: ${total} points/hour exceeds the ${QUOTA}/hour GraphQL quota.

The quota is per account and every job shares gh-token, so this would make reads fail
part way through a run. Each failure is an ERROR pr.read_failed, and after three in a
row the run stops with reason=read_failures, leaving the rest for the next run.

Lengthen a schedule (*/30 halves a job's share), lower expected_open_prs if it is
overstated, or give a job a token for a second account. Another token for the same
account adds no quota. Raising max_requests_per_run will not help: almost all of the
cost is reads.
EOF
    exit 1
fi

if ((total * 100 / QUOTA >= WARN_PERCENT)); then
    printf '\n::warning::copilot-review-bot is at %s%% of the GraphQL quota (%s/%s points per hour). Lengthen a schedule before adding another repo.\n' \
        "$((total * 100 / QUOTA))" "${total}" "${QUOTA}" >&2
fi

# expected_open_prs is a declared allowance, not a measurement, so it goes stale
# upwards as a repo grows. The bot logs the real count as `open_prs` on its
# repo.start event, which is what to compare against.
printf 'within budget. Compare against reality with:\n'
printf "  gcloud logging read 'jsonPayload.event=\"repo.start\"' --limit 10 \\\\\n"
printf "      --format 'value(jsonPayload.repo, jsonPayload.open_prs)'\n"

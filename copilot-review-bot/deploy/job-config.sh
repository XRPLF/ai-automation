# shellcheck shell=bash
#
# job-config.sh - turn one jobs.json entry into the three things GCP needs: a Cloud Run
# job name, a Cloud Scheduler cron expression, and the tick count the budget is charged on.
#
# Sourced by both deploy-job.sh and rate-budget.sh, never executed. They are the only two
# readers of jobs.json and they have to agree exactly: rate-budget.sh charges a fleet that
# deploy-job.sh then creates, so a derivation that differed between them would pass the
# budget check and deploy something else. deploy-job-test.sh asserts they agree.
#
# Nothing here is in the runtime image. The Dockerfile copies the bot and the entrypoint
# only, and CI asserts /app holds nothing else.

# The longest a Cloud Run job name may be. Stated as a constant because it is a platform
# limit rather than a choice, and because the derived name below has to fit inside it after
# the 19-character prefix. If the platform limit turns out to be higher, raising this only
# ever accepts more names, so the direction of the error is safe: too long is refused with
# a message naming the fix.
#
# Neither `gcloud run jobs create --help` nor the v2 discovery document states the limit, so
# confirm it without creating anything by using the API's own validateOnly:
#
#     curl -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" \
#       "https://run.googleapis.com/v2/projects/PROJECT/locations/REGION/jobs?jobId=NAME&validateOnly=true" \
#       -H 'Content-Type: application/json' --data '{"template":{"template":{"containers":[{"image":"IMAGE"}]}}}'
#
# Read by rate-budget.sh rather than here, which is what shellcheck cannot see across a
# source boundary.
# shellcheck disable=SC2034
JOB_NAME_MAX_LENGTH=49

# The prefix every job name carries. Load-bearing: every alert filter in deploy/README.md
# is a prefix match on it, so a job without it would tick, file real review requests, and
# be invisible to every metric.
JOB_NAME_PREFIX="copilot-review-bot"

# owner/name -> the Cloud Run job name.
#
# Derived rather than declared, so it cannot disagree with the repository it watches and
# cannot collide by hand: `repo` is already unique per entry, so the name is too, save for
# the folding below. Callers still assert uniqueness on the result.
#
# GitHub allows '.' and '_' in an owner or a repository name and Cloud Run allows neither,
# so both fold to '-'. That folding is not injective - `a-b/c` and `a/b-c` both give
# `a-b-c` - which is why the uniqueness check runs on this output and not on `repo`.
job_name_for() { # <owner/name>
    local slug="${1,,}"
    # Anything Cloud Run will not take becomes a hyphen, then runs of hyphens collapse and
    # any leading or trailing one is dropped: a name may not begin or end with a hyphen.
    slug="${slug//[^a-z0-9]/-}"
    while [[ "${slug}" == *--* ]]; do slug="${slug//--/-}"; done
    slug="${slug#-}"
    slug="${slug%-}"
    printf '%s-%s' "${JOB_NAME_PREFIX}" "${slug}"
}

# The minute step between ticks. Only counts that divide 60 give evenly spaced ticks, which
# is what callers check before reaching this.
TICK_COUNTS_ALLOWED="1 2 3 4 5 6 10 12 15 20 30 60"

tick_count_is_valid() { # <ticks-per-hour>
    local n
    for n in ${TICK_COUNTS_ALLOWED}; do
        [[ "$1" == "${n}" ]] && return 0
    done
    return 1
}

# A stable offset for a repository, in 0..step-1.
#
# Derived from the repository rather than from its position in jobs.json, so inserting or
# removing an entry never moves anybody else's tick. An index would renumber the whole
# fleet on every edit, which is a schedule change nobody asked for.
#
# cksum is in coreutils and this runs in CI, never in the runtime image. Collisions are
# possible and harmless: two jobs sharing a minute is two concurrent request streams, far
# below anything GitHub objects to. Set offset_minutes explicitly to pin one.
offset_for() { # <owner/name> <step>
    local sum
    sum="$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
    printf '%s' "$((sum % $2))"
}

# The Cloud Scheduler cron for a tick count and an offset.
#
# Only the minute field is ever used, because a job that is not hourly cannot be budgeted
# per hour. That was true of the hand-written cron this replaces too, which is why the
# schema takes a count and an offset and builds the expression here: a count states the
# hourly spend directly, where `*/N` had to be turned back into one by ceiling division.
schedule_for() { # <ticks-per-hour> <offset-minutes>
    local count="$1" offset="$2" step=$((60 / $1)) i minutes=()
    for ((i = 0; i < count; i++)); do
        minutes+=("$(((offset + i * step) % 60))")
    done
    # Sorted, so the expression reads in the order the ticks fire within the hour and two
    # equivalent offsets produce one string rather than a rotation of it.
    local sorted
    sorted="$(printf '%s\n' "${minutes[@]}" | sort -n | paste -sd, -)"
    printf '%s * * * *' "${sorted}"
}

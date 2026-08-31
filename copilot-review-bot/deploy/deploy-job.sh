#!/usr/bin/env bash
#
# deploy-job.sh - create or update one Cloud Run job and the Cloud Scheduler job
# that ticks it, from an entry in jobs.json.
#
# Idempotent, and run for every job on every push to main, so jobs.json is the
# source of truth rather than whatever somebody last typed at gcloud. That cuts
# both ways and it is deliberate: an emergency change made by hand is corrected on
# the next merge, so an incident fix has to land in jobs.json to survive.
#
# jobs.json is validated by rate-budget.sh, which runs in the `test` job before
# anything is built and is the only place that sees every entry at once. The checks
# here are a fail-safe for a direct invocation, not the primary gate.
#
# Keyed on the repository rather than on a job name, because the repository is the primary
# key: it is required, it is unique, and the Cloud Run job name is derived from it by
# job-config.sh. An entry may still declare `name` for the cases the derivation cannot
# serve, and this reads that when it is there.
#
# Usage: ./deploy-job.sh <owner/name> [path-to-jobs.json]
#
# Environment:
#   IMAGE     (required) fully qualified image, pinned to a digest.
#   PROJECT   (required) GCP project.
#   REGION    (required) GCP region.
#   BUCKET    (required) state bucket name, without the gs:// prefix.
#   GCLOUD    the gcloud to run. Overridable so the test can record the calls,
#             and so `GCLOUD=echo` prints what a real run would do.
#
set -Eeuo pipefail

SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=job-config.sh
. "${SUITE_DIR}/job-config.sh"
REPO_KEY="${1:?usage: deploy-job.sh <owner/name> [jobs.json]}"
JOBS="${2:-${SUITE_DIR}/jobs.json}"
GCLOUD="${GCLOUD:-gcloud}"

for v in IMAGE PROJECT REGION BUCKET; do
    [[ -n "${!v:-}" ]] || {
        echo "${v} must be set" >&2
        exit 2
    }
done
# jq before the file, because every read below goes through it and a missing jq would
# otherwise surface as "command not found" and exit 127 rather than as a configuration
# error. rate-budget.sh is the primary gate for jobs.json and checks all three of these;
# they are repeated here because this script is also the fail-safe for a direct
# invocation, and a fail-safe that exits 127 with jq's raw parse error is not one.
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

# Exactly one match, counted before anything is read out of it. `.jobs[] | select(...)`
# yields every match, so two entries sharing a name would produce a two-object stream,
# every field below would read as two lines, and the job would be deployed with
# newlines in its environment and two repositories in REPO - reporting success.
# rate-budget.sh rejects duplicate names outright; this is what stops a direct
# invocation getting there. Counted rather than asserted inside jq, so both outcomes
# exit 2 like every other configuration error here rather than passing jq's own status
# through.
matches="$(jq --arg n "${REPO_KEY}" '[.jobs[] | select(.repo == $n)] | length' "${JOBS}")"
case "${matches}" in
    1) ;;
    0)
        echo "no job for repository '${REPO_KEY}' in ${JOBS}" >&2
        exit 2
        ;;
    *)
        echo "'${REPO_KEY}' appears ${matches} times in ${JOBS}; repo values must be unique" >&2
        exit 2
        ;;
esac
entry="$(jq -c --arg n "${REPO_KEY}" 'first(.jobs[] | select(.repo == $n))' "${JOBS}")"

# `has`, not jq's `//`: `false // "x"` is "x", because jq counts false as empty. So
# `//` would quietly turn "verbose": false into the default of true, and a job asked
# to be quiet would log every PR.
field() { # <key> [default]
    jq -r --arg k "$1" --arg d "${2-}" \
        'if has($k) and .[$k] != null then .[$k] else $d end' <<<"${entry}"
}

REPO="$(field repo)"
# Derived, not declared, so the job name cannot disagree with the repository it watches.
# An explicit `name` wins, for the cases job_name_for cannot serve.
NAME="$(field name)"
[[ -n "${NAME}" ]] || NAME="$(job_name_for "${REPO}")"
# Built from a count and an offset rather than read as a cron, because only the minute
# field was ever used. An absent offset is derived from the repository, so two jobs never
# share a tick minute by default and inserting one never moves anybody else's.
TICKS="$(field ticks_per_hour)"
OFFSET="$(field offset_minutes)"
MAX_REQUESTS="$(field max_requests_per_run)"
# Passed to the bot only so a run can say when it has gone stale. Nothing enforces it: the
# run reads however many PRs there are. rate-budget.sh charges the quota at this figure, and
# this is the only way the bot ever learns what that figure was.
EXPECTED_OPEN_PRS="$(field expected_open_prs)"
MENTION_WRITES="$(field max_mention_writes_per_run 50)"
DRY_RUN="$(field dry_run false)"
# Verbose by default, deliberately, while the decision rules are still new: pr.evaluated
# carries the whole decision record, so a wrong call can be audited from the log without
# re-querying GitHub. It costs about 900 log lines and 22,000 bash subshells per run at
# 300 PRs, both comfortably inside the free tier. Set "verbose": false once the rules
# stop being the thing under suspicion.
VERBOSE="$(field verbose true)"
TASK_TIMEOUT="$(field task_timeout 20m)"
LOCK_TTL="$(field lock_ttl_minutes 25)"
DEADLINE="$(field run_deadline_seconds 900)"
MEMORY="$(field memory 512Mi)"

# Every field rate-budget.sh requires, checked again here so a direct invocation fails the
# same way rather than deploying something half configured. expected_open_prs is in the list
# because an empty one silently switches off the bot's own drift warning, which is the whole
# reason the figure reaches the job at all.
#
# Named by the jobs.json field rather than by the variable this script happens to hold it in:
# "missing ticks" would send a reader looking for a key that does not exist.
for spec in REPO:repo TICKS:ticks_per_hour MAX_REQUESTS:max_requests_per_run \
    EXPECTED_OPEN_PRS:expected_open_prs; do
    v="${spec%%:*}"
    [[ -n "${!v}" ]] || {
        echo "job '${NAME}' is missing ${spec#*:}" >&2
        exit 2
    }
done

# Checked here as well as in rate-budget.sh, which is the primary gate: an uneven step
# would put the ticks at minutes that do not repeat hour to hour, and the budget arithmetic
# assumes they do. A direct invocation has to fail on it too.
tick_count_is_valid "${TICKS}" || {
    echo "job '${NAME}': ticks_per_hour must divide 60 evenly, not '${TICKS}'" >&2
    exit 2
}
[[ -n "${OFFSET}" ]] || OFFSET="$(offset_for "${REPO}" $((60 / TICKS)))"
SCHEDULE="$(schedule_for "${TICKS}" "${OFFSET}")"

# Anything but the two literals is refused rather than defaulted. entrypoint.sh maps
# "true" to a flag and treats everything else as false, so "yes" or "1" in DRY_RUN
# would silently mean "not a dry run" and file real review requests.
for v in DRY_RUN VERBOSE; do
    [[ "${!v}" =~ ^(true|false)$ ]] || {
        echo "job '${NAME}': ${v,,} must be true or false, not '${!v}'" >&2
        exit 2
    }
done

# A custom delimiter, because --set-env-vars splits on commas by default, and a comma
# reaching any value below would then be read as the start of another variable. ^@^ says
# "@ separates these". rate-budget.sh rejects an @ in any jobs.json value, which is what
# makes that safe.
ENV_VARS="^@^REPO=${REPO}"
# The bucket root, with no prefix: the bot puts both the lock and the markers under
# <owner>/<name> itself, so every job can share one root and nothing per-job has to be
# kept unique by hand.
ENV_VARS+="@STATE_DIR=gs://${BUCKET}"
ENV_VARS+="@DRY_RUN=${DRY_RUN}"
ENV_VARS+="@VERBOSE=${VERBOSE}"
ENV_VARS+="@MAX_REQUESTS_PER_RUN=${MAX_REQUESTS}"
ENV_VARS+="@MAX_MENTION_WRITES_PER_RUN=${MENTION_WRITES}"
ENV_VARS+="@EXPECTED_OPEN_PRS=${EXPECTED_OPEN_PRS}"
ENV_VARS+="@LOCK_TTL_MINUTES=${LOCK_TTL}"
# Set here rather than left to the bot's own default, because it has to sit below
# --task-timeout and that is set here too. rate-budget.sh asserts the ordering.
ENV_VARS+="@RUN_DEADLINE_SECONDS=${DEADLINE}"

# --set-env-vars, not --update-env-vars: the set is replaced, so a variable added by
# hand outside this list is removed on the next merge. An env var nobody can find in
# the repository is how the bot ends up running in a mode nobody chose. Note that
# dropping a key from jobs.json does not unset anything, because every variable below
# is emitted unconditionally; it falls back to the default beside it.
job_args=(
    --image "${IMAGE}"
    --region "${REGION}" --project "${PROJECT}"
    --service-account "bot-runtime@${PROJECT}.iam.gserviceaccount.com"
    --set-secrets GH_TOKEN=gh-token:latest
    --set-env-vars "${ENV_VARS}"
    --max-retries 0
    --task-timeout "${TASK_TIMEOUT}"
    --memory "${MEMORY}"
    # Stated rather than left to the default, so a value set by hand is corrected on
    # the next merge like everything else here. Two tasks would race for one lock.
    --tasks 1
    --parallelism 1
)

# The scheduler needs no per-job invoker binding, because scheduler-invoker holds
# roles/run.invoker at project level. Without that this script would also need
# setIamPolicy, which means roles/run.admin for the deployer rather than
# roles/run.developer. See ./README.md.
TICK="${NAME}-tick"
URI="https://run.googleapis.com/v2/projects/${PROJECT}/locations/${REGION}/jobs/${NAME}:run"
tick_args=(
    --location "${REGION}" --project "${PROJECT}"
    --schedule "${SCHEDULE}"
    --uri "${URI}"
    --http-method POST
    --oauth-service-account-email "scheduler-invoker@${PROJECT}.iam.gserviceaccount.com"
)

# The tick goes first, deliberately. These are two unrelated calls with no rollback
# between them, so `set -e` can leave the first applied and the second not. Of the two
# half-states, a tick whose job does not exist yet fails loudly on its next firing,
# while a job with no tick simply never runs and nobody notices. Both are repaired by
# the next merge; only one of them says so.
#
# describe decides create against update, because `create` fails on a job that
# exists and `update` fails on one that does not. Its output is discarded: the only
# question is whether it succeeds.
if "${GCLOUD}" scheduler jobs describe "${TICK}" \
    --location "${REGION}" --project "${PROJECT}" >/dev/null 2>&1; then
    echo "updating Cloud Scheduler job ${TICK}"
    "${GCLOUD}" scheduler jobs update http "${TICK}" "${tick_args[@]}"
else
    echo "creating Cloud Scheduler job ${TICK}"
    "${GCLOUD}" scheduler jobs create http "${TICK}" "${tick_args[@]}"
fi

if "${GCLOUD}" run jobs describe "${NAME}" \
    --region "${REGION}" --project "${PROJECT}" >/dev/null 2>&1; then
    echo "updating Cloud Run job ${NAME}"
    "${GCLOUD}" run jobs update "${NAME}" "${job_args[@]}"
else
    echo "creating Cloud Run job ${NAME}"
    "${GCLOUD}" run jobs create "${NAME}" "${job_args[@]}"
fi

# The two paths are named apart on purpose. STATE_DIR is the bucket root, shared by every
# job, and the bot appends the repository to it, so the second path is where this job's lock
# and markers actually land. Printing only the second invites somebody to paste it back into
# STATE_DIR, which would nest the repository twice.
echo "${NAME} deployed: ${REPO} on ${SCHEDULE}"
echo "  STATE_DIR=gs://${BUCKET} (shared root), this job's state under gs://${BUCKET}/${REPO}/"

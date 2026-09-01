#!/usr/bin/env bash
#
# deploy-job-test.sh - drive deploy-job.sh and rate-budget.sh against a fake gcloud
# and assert on the commands they would run.
#
# These two are the only things in the repository that change production without a
# human reading the command first, and neither is exercised by any other suite. A
# mistake in deploy-job.sh points a live job at the wrong repo or the wrong state
# bucket; a mistake in rate-budget.sh lets a deployment through that makes reads fail
# part way through a run.
#
# No network, no GCP and no gcloud: the fake records its argv and answers `describe`
# from a control file, so both the create and the update path are reachable.
#
# Usage: ./deploy-job-test.sh
#
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test-lib.sh
. "${SUITE_DIR}/test-lib.sh"

# The scripts under test, and the jobs.json they default to, live one level up in
# deploy/. Resolved once here so the assertions below name a file rather than a path
# expression.
DEPLOY_DIR="$(cd "${SUITE_DIR}/../deploy" && pwd)"
DEPLOY="${DEPLOY_DIR}/deploy-job.sh"
BUDGET="${DEPLOY_DIR}/rate-budget.sh"
for s in "${DEPLOY}" "${BUDGET}"; do
    [[ -x "${s}" ]] || {
        echo "cannot execute ${s}" >&2
        exit 2
    }
done
require_tools jq
# Hoisted, like the other suites do: one call, so the "no extra binaries needed"
# note lives in one place. Nothing here runs anything but jq, bash and the fake.
# shellcheck disable=SC2119
TOOL_PATH="$(build_tool_path)"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

# ---------------------------------------------------------------------------
# The fake gcloud. One line per call in calls.log, and `describe` succeeds only
# when the matching exists-* marker is present, which is what selects create
# against update.
# ---------------------------------------------------------------------------
FAKE="${ROOT}/gcloud"
cat >"${FAKE}" <<'GCLOUD'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"${CALLS}"
if [[ "$2" == jobs && "$3" == describe ]]; then
    [[ "$1" == run && -f "${FAKE_DIR}/exists-run" ]] && exit 0
    [[ "$1" == scheduler && -f "${FAKE_DIR}/exists-scheduler" ]] && exit 0
    exit 1
fi
exit 0
GCLOUD
chmod +x "${FAKE}"

JOBS="${ROOT}/jobs.json"
cat >"${JOBS}" <<'JSON'
{
  "jobs": [
    {
      "repo": "XRPLF/rippled",
      "ticks_per_hour": 4,
      "offset_minutes": 3,
      "expected_open_prs": 300,
      "max_requests_per_run": 25
    },
    {
      "name": "copilot-review-bot-tuned",
      "repo": "XRPLF/clio",
      "ticks_per_hour": 2,
      "offset_minutes": 7,
      "expected_open_prs": 40,
      "max_requests_per_run": 5,
      "max_mention_writes_per_run": 10,
      "dry_run": true,
      "verbose": false,
      "task_timeout": "10m",
      "lock_ttl_minutes": 12,
      "run_deadline_seconds": 500,
      "memory": "256Mi"
    }
  ]
}
JSON

# deploy <job-name> [extra env...] -> ${rc}, calls in ${ROOT}/calls.log
deploy() {
    local name="$1"
    shift
    : >"${ROOT}/calls.log"
    rc=0
    env -i \
        PATH="${TOOL_PATH}" \
        HOME="${ROOT}" \
        CALLS="${ROOT}/calls.log" \
        FAKE_DIR="${ROOT}" \
        GCLOUD="${FAKE}" \
        IMAGE=registry/copilot-review-bot:sha123 \
        PROJECT=xrplf-automation \
        REGION=us-central1 \
        BUCKET=state-bucket \
        "$@" \
        "${BASH}" "${DEPLOY}" "${name}" "${JOBS}" \
        >"${ROOT}/out.log" 2>"${ROOT}/err.log" || rc=$?
    LAST_LOG="${ROOT}/out.log"
}

calls_matching() { # <pattern>
    grep -c -- "$1" "${ROOT}/calls.log" 2>/dev/null || true
}

# ===========================================================================
printf '\n== a job that does not exist yet is created, not updated ==\n'
rm -f "${ROOT}/exists-run" "${ROOT}/exists-scheduler"
deploy XRPLF/rippled
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the Cloud Run job was created" 1 "$(calls_matching '^run jobs create copilot-review-bot-xrplf-rippled ')"
assert_eq "and not updated" 0 "$(calls_matching '^run jobs update ')"
assert_eq "the scheduler job was created" 1 "$(calls_matching '^scheduler jobs create http copilot-review-bot-xrplf-rippled-tick ')"
assert_eq "and not updated" 0 "$(calls_matching '^scheduler jobs update ')"

# ===========================================================================
printf '\n== a job that exists is updated, not created ==\n'
# Both verbs are needed because create fails on an existing job and update fails on
# a missing one, so picking the wrong one breaks every push after the first.
touch "${ROOT}/exists-run" "${ROOT}/exists-scheduler"
deploy XRPLF/rippled
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the Cloud Run job was updated" 1 "$(calls_matching '^run jobs update copilot-review-bot-xrplf-rippled ')"
assert_eq "and not created" 0 "$(calls_matching '^run jobs create ')"
assert_eq "the scheduler job was updated" 1 "$(calls_matching '^scheduler jobs update http copilot-review-bot-xrplf-rippled-tick ')"

# ===========================================================================
printf '\n== the two halves are decided independently ==\n'
# A job created by hand without its tick, or a tick left behind by a rename, both
# happen. Deciding both from one describe would then take the wrong verb for one.
rm -f "${ROOT}/exists-scheduler"
touch "${ROOT}/exists-run"
deploy XRPLF/rippled
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the job was updated" 1 "$(calls_matching '^run jobs update ')"
assert_eq "but the tick was created" 1 "$(calls_matching '^scheduler jobs create http ')"

# ===========================================================================
printf '\n== the environment carries the repo and the shared state root ==\n'
# STATE_DIR is the bucket root, with no prefix, because the bot puts both the lock and
# the markers under <owner>/<name> itself. A prefix here would nest that inside a second
# one chosen by hand, which is the thing the repository-derived path exists to avoid.
rm -f "${ROOT}/exists-run" "${ROOT}/exists-scheduler"
deploy XRPLF/rippled
assert_eq "REPO names the one repo" 1 "$(calls_matching 'REPO=XRPLF/rippled@')"
assert_eq "STATE_DIR is the bucket root" 1 \
    "$(calls_matching 'STATE_DIR=gs://state-bucket@')"
assert_eq "the image is the pinned one" 1 "$(calls_matching '--image registry/copilot-review-bot:sha123')"
assert_eq "the token comes from Secret Manager" 1 "$(calls_matching '--set-secrets GH_TOKEN=gh-token:latest')"

# ===========================================================================
printf '\n== the env set is replaced, not merged ==\n'
# --update-env-vars would leave behind a variable dropped from jobs.json, so the job
# would keep running in a mode nobody can find in the repository.
assert_eq "--set-env-vars is used" 1 "$(calls_matching '--set-env-vars')"
assert_eq "--update-env-vars is not" 0 "$(calls_matching '--update-env-vars')"

# ===========================================================================
printf '\n== the env list uses a delimiter that cannot appear in a value ==\n'
# gcloud splits --set-env-vars on commas by default, so a comma reaching any value
# would silently split it into two variables. The delimiter is declared rather than
# relied on being absent, because nothing about a value's contents is this script's to
# assume.
assert_eq "a custom delimiter is declared" 1 "$(calls_matching '--set-env-vars \^@\^')"
assert_eq "no comma separates the pairs" 0 "$(calls_matching 'REPO=XRPLF/rippled,')"

# ===========================================================================
printf '\n== defaults apply, and every one of them can be overridden ==\n'
deploy XRPLF/rippled
assert_eq "DRY_RUN defaults to false" 1 "$(calls_matching 'DRY_RUN=false@')"
assert_eq "VERBOSE defaults to true" 1 "$(calls_matching 'VERBOSE=true@')"
assert_eq "the cap defaults from the file" 1 "$(calls_matching 'MAX_REQUESTS_PER_RUN=25@')"
assert_eq "the mention cap defaults to 50" 1 "$(calls_matching 'MAX_MENTION_WRITES_PER_RUN=50@')"
# Reaches the bot only so a run can report that it has gone stale. rate-budget.sh charges
# the quota at it, and this is the only path by which the bot learns the figure.
assert_eq "the expected PR count is passed through" 1 "$(calls_matching 'EXPECTED_OPEN_PRS=300@')"
assert_eq "the lock TTL defaults to 25" 1 "$(calls_matching 'LOCK_TTL_MINUTES=25@')"
assert_eq "the run deadline defaults to 900" 1 "$(calls_matching 'RUN_DEADLINE_SECONDS=900')"
assert_eq "the timeout defaults to 20m" 1 "$(calls_matching '--task-timeout 20m')"
assert_eq "memory defaults to 512Mi" 1 "$(calls_matching '--memory 512Mi')"
# Stated rather than left to the platform default, so a hand-set value is corrected on
# the next merge. Two tasks would race for one lock object.
assert_eq "one task, no parallelism" 1 "$(calls_matching '--tasks 1 --parallelism 1')"

deploy XRPLF/clio
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "DRY_RUN is overridden" 1 "$(calls_matching 'DRY_RUN=true@')"
assert_eq "VERBOSE is overridden" 1 "$(calls_matching 'VERBOSE=false@')"
assert_eq "the cap is overridden" 1 "$(calls_matching 'MAX_REQUESTS_PER_RUN=5@')"
assert_eq "the mention cap is overridden" 1 "$(calls_matching 'MAX_MENTION_WRITES_PER_RUN=10@')"
assert_eq "the lock TTL is overridden" 1 "$(calls_matching 'LOCK_TTL_MINUTES=12@')"
assert_eq "the run deadline is overridden" 1 "$(calls_matching 'RUN_DEADLINE_SECONDS=500')"
assert_eq "the timeout is overridden" 1 "$(calls_matching '--task-timeout 10m')"
assert_eq "memory is overridden" 1 "$(calls_matching '--memory 256Mi')"
assert_eq "its own schedule is used" 1 "$(calls_matching '--schedule 7,37 \* \* \* \*')"
assert_eq "and its own repo" 1 "$(calls_matching 'REPO=XRPLF/clio@')"
# The same root for every job, deliberately: the bot namespaces the state by repository
# itself, so nothing here has to be kept unique by hand.
assert_eq "but the same state root" 1 "$(calls_matching 'STATE_DIR=gs://state-bucket@')"

# ===========================================================================
printf '\n== the tick is written before the job, so a half-deploy is loud ==\n'
# Two unrelated calls with no rollback between them, so one can land without the
# other. A tick whose job does not exist fails on its next firing; a job with no tick
# never runs and nobody notices. Only one of those two half-states reports itself.
rm -f "${ROOT}/exists-run" "${ROOT}/exists-scheduler"
deploy XRPLF/rippled
assert_eq "the scheduler call comes first" "scheduler" \
    "$(awk 'NR == 1 {print $1}' "${ROOT}/calls.log")"

# ===========================================================================
printf '\n== a duplicate name is refused rather than deployed twice over ==\n'
# `.jobs[] | select(.name == $n)` yields every match, so two entries sharing a name
# would put both repos in REPO and a newline in STATE_DIR, and report success.
dup="${ROOT}/dup.json"
jq '{jobs: [.jobs[0], .jobs[0]]}' "${JOBS}" >"${dup}"
: >"${ROOT}/calls.log"
rc=0
env -i PATH="${TOOL_PATH}" HOME="${ROOT}" CALLS="${ROOT}/calls.log" \
    FAKE_DIR="${ROOT}" GCLOUD="${FAKE}" IMAGE=i PROJECT=p REGION=r BUCKET=b \
    "${BASH}" "${DEPLOY}" XRPLF/rippled "${dup}" \
    >"${ROOT}/out.log" 2>"${ROOT}/err.log" || rc=$?
assert_eq "exit status is 2, not jq's own" 2 "${rc}"
assert_eq "no gcloud call was made" 0 "$(wc -l <"${ROOT}/calls.log" | tr -d ' ')"
assert_contains "it says how many it found" "appears 2 times" "$(cat "${ROOT}/err.log")"

# ===========================================================================
printf '\n== a boolean that is not true or false is refused, not defaulted ==\n'
# entrypoint.sh maps exactly "true" to a flag, so "yes" would silently mean "not a dry
# run" and the job would file real review requests.
for bad in yes 1 True TRUE on; do
    badbool="${ROOT}/badbool.json"
    jq --arg v "${bad}" '.jobs[0].dry_run = $v' "${JOBS}" >"${badbool}"
    : >"${ROOT}/calls.log"
    rc=0
    env -i PATH="${TOOL_PATH}" HOME="${ROOT}" CALLS="${ROOT}/calls.log" \
        FAKE_DIR="${ROOT}" GCLOUD="${FAKE}" IMAGE=i PROJECT=p REGION=r BUCKET=b \
        "${BASH}" "${DEPLOY}" XRPLF/rippled "${badbool}" \
        >"${ROOT}/out.log" 2>"${ROOT}/err.log" || rc=$?
    assert_eq "dry_run '${bad}' is exit 2" 2 "${rc}"
    assert_eq "dry_run '${bad}' makes no call" 0 "$(wc -l <"${ROOT}/calls.log" | tr -d ' ')"
done

# ===========================================================================
printf '\n== the tick points at this job, and runs as the invoker account ==\n'
deploy XRPLF/clio
assert_eq "the URI names the job" 1 \
    "$(calls_matching 'jobs/copilot-review-bot-tuned:run')"
assert_eq "it posts" 1 "$(calls_matching '--http-method POST')"
assert_eq "as scheduler-invoker" 1 \
    "$(calls_matching 'scheduler-invoker@xrplf-automation.iam.gserviceaccount.com')"

# ===========================================================================
printf '\n== a name that is not in the file is refused, and changes nothing ==\n'
deploy XRPLF/nope
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "no gcloud call was made" 0 "$(wc -l <"${ROOT}/calls.log" | tr -d ' ')"
assert_contains "it names the repository it could not find" "XRPLF/nope" "$(cat "${ROOT}/err.log")"

# ===========================================================================
printf '\n== a missing required jobs.json field is refused, by field name ==\n'
# rate-budget.sh is the primary schema gate, but deploy-job.sh is the fail-safe for a direct
# invocation, so every field it requires has to fail here too. expected_open_prs is in the
# list because an empty one silently disables the bot's drift warning rather than breaking
# anything visibly, which is the worst shape for a missing value.
# repo is not in this list because it is the lookup key: without it the entry cannot be
# found at all, which is the "no job for repository" path a few cases below.
for spec in ticks_per_hour max_requests_per_run expected_open_prs; do
    stripped="${ROOT}/no-${spec}.json"
    jq --arg k "${spec}" 'del(.jobs[0][$k])' "${JOBS}" >"${stripped}"
    : >"${ROOT}/calls.log"
    rc=0
    env -i PATH="${TOOL_PATH}" HOME="${ROOT}" CALLS="${ROOT}/calls.log" \
        FAKE_DIR="${ROOT}" GCLOUD="${FAKE}" IMAGE=i PROJECT=p REGION=r BUCKET=b \
        "${BASH}" "${DEPLOY}" XRPLF/rippled "${stripped}" \
        >"${ROOT}/out.log" 2>"${ROOT}/err.log" || rc=$?
    assert_eq "a missing ${spec} is exit 2" 2 "${rc}"
    # Named by the field, not by the variable: "missing ticks" sends a reader looking for a
    # key that does not exist.
    assert_contains "and it names ${spec}" "missing ${spec}" "$(cat "${ROOT}/err.log")"
    assert_eq "a missing ${spec} makes no call" 0 "$(wc -l <"${ROOT}/calls.log" | tr -d ' ')"
done

printf '\n== a missing required variable is refused before any call ==\n'
for missing in IMAGE PROJECT REGION BUCKET; do
    : >"${ROOT}/calls.log"
    rc=0
    env -i PATH="${TOOL_PATH}" HOME="${ROOT}" CALLS="${ROOT}/calls.log" \
        FAKE_DIR="${ROOT}" GCLOUD="${FAKE}" \
        IMAGE=i PROJECT=p REGION=r BUCKET=b "${missing}=" \
        "${BASH}" "${DEPLOY}" XRPLF/rippled "${JOBS}" \
        >"${ROOT}/out.log" 2>"${ROOT}/err.log" || rc=$?
    assert_eq "${missing} unset is exit 2" 2 "${rc}"
    assert_eq "${missing} unset makes no call" 0 "$(wc -l <"${ROOT}/calls.log" | tr -d ' ')"
done

# ===========================================================================
# rate-budget.sh
# ===========================================================================
budget() { # <jobs-file> [env...]
    rc=0
    env -i PATH="${TOOL_PATH}" HOME="${ROOT}" "${@:2}" \
        "${BASH}" "${BUDGET}" "$1" >"${ROOT}/budget.log" 2>"${ROOT}/budget.err" || rc=$?
    LAST_LOG="${ROOT}/budget.log"
}

# One tab-separated `budget` line per job, plus a TOTAL line. Asserted on instead of
# the table, so re-formatting the table's columns cannot break these.
budget_row() { # <job-name> -> "<runs/h> <pts/run> <pts/h>"
    awk -F'\t' -v n="$1" '$1 == "budget" && $2 == n {print $3, $4, $5}' \
        "${ROOT}/budget.log"
}

printf '\n== a schedule inside the quota is allowed, with the arithmetic shown ==\n'
# 300 PRs: 1 viewer call at 1, 3 list calls at 1, 300 reads at 2, 25 requests at 3 and
# 50 mention writes at 1 = 729 per run, four runs an hour = 2916. Asserted as numbers
# so a change to the cost model has to be deliberate.
one="${ROOT}/one.json"
jq '{jobs: [.jobs[0]]}' "${JOBS}" >"${one}"
budget "${one}"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the arithmetic is per-job and exact" "4 729 2916" \
    "$(budget_row copilot-review-bot-xrplf-rippled)"
assert_contains "and the percentage of quota" "58%" "$(cat "${ROOT}/budget.log")"

printf '\n== a second big repo on the same token is refused ==\n'
# The failure this whole script exists for. Two rippled-sized repos on */15 is
# 5424 points an hour against a 5000 quota, and the symptom in production is reads
# failing part way through a run with PRs skipped and nothing saying so.
two="${ROOT}/two.json"
jq '{jobs: [.jobs[0], (.jobs[0] | .repo = "XRPLF/other")]}' "${JOBS}" >"${two}"
budget "${two}"
assert_eq "exit status is 1" 1 "${rc}"
assert_contains "it says it is refusing" "REFUSING" "$(cat "${ROOT}/budget.err")"
assert_contains "it suggests lengthening a schedule" "*/30" "$(cat "${ROOT}/budget.err")"

printf '\n== halving the tick count brings the same two repos back inside ==\n'
# The documented lever, asserted rather than asserted-in-prose: half the ticks is half a
# job's hourly share, so the pair fits where at four an hour it did not.
half="${ROOT}/half.json"
jq '[.jobs[] | .ticks_per_hour = 2] | {jobs: .}' "${two}" >"${half}"
budget "${half}"
assert_eq "exit status is 0" 0 "${rc}"
assert_contains "it is now inside the quota" "within budget" "$(cat "${ROOT}/budget.log")"

printf '\n== approaching the ceiling warns before it refuses ==\n'
near="${ROOT}/near.json"
jq '{jobs: [(.jobs[0] | .expected_open_prs = 500)]}' "${JOBS}" >"${near}"
budget "${near}"
assert_eq "exit status is 0" 0 "${rc}"
assert_contains "it warns" "::warning::" "$(cat "${ROOT}/budget.err")"

printf '\n== a tick count that does not divide 60 is refused, not rounded ==\n'
# An uneven step would put the ticks at minutes that do not repeat hour to hour, so the
# hourly arithmetic below would be wrong. Refused rather than rounded: a silently wrong
# divisor turns this whole check into decoration.
for bad in 7 8 9 11 13 45 61 0; do
    odd="${ROOT}/odd.json"
    jq --argjson t "${bad}" '{jobs: [(.jobs[0] | .ticks_per_hour = $t)]}' "${JOBS}" >"${odd}"
    budget "${odd}"
    assert_eq "ticks_per_hour ${bad} is refused" 2 "${rc}"
    assert_contains "and it lists the counts that work" "must divide 60" "$(cat "${ROOT}/budget.err")"
done

printf '\n== every tick count that divides 60 is counted, and builds its own cron ==\n'
# per_run is fixed at 729 by the first entry, so the hourly total is the count times it.
# The generated cron is asserted too: the count decides how many minutes it lists, and
# nothing else in the expression ever varies.
for want in 1 2 3 4 5 6 10 12 15 20 30 60; do
    ok="${ROOT}/ok.json"
    jq --argjson t "${want}" \
        '{jobs: [(.jobs[0] | .ticks_per_hour = $t | .offset_minutes = 0)]}' "${JOBS}" >"${ok}"
    budget "${ok}"
    assert_eq "${want} ticks an hour is counted as ${want}" "${want} 729 $((729 * want))" \
        "$(budget_row copilot-review-bot-xrplf-rippled)"
    assert_eq "and its cron lists ${want} minute(s)" "${want}" \
        "$(sed -n 's/.*  \([0-9,]*\) \* \* \* \*.*/\1/p' "${ROOT}/budget.log" | head -1 | awk -F, '{print NF}')"
done

printf '\n== the offset places the ticks, and defaults to something stable ==\n'
# An explicit offset is used as given. Without one it is derived from the repository, so
# two entries do not share a minute and inserting one never moves anybody else's tick.
off="${ROOT}/off.json"
jq '{jobs: [(.jobs[0] | .ticks_per_hour = 4 | .offset_minutes = 9)]}' "${JOBS}" >"${off}"
budget "${off}"
assert_eq "exit status is 0" 0 "${rc}"
assert_contains "an explicit offset is used verbatim" "9,24,39,54 * * * *" \
    "$(cat "${ROOT}/budget.log")"

# Derived twice from the same repo, so it has to come out the same both times.
der="${ROOT}/der.json"
jq '{jobs: [(.jobs[0] | .ticks_per_hour = 4 | del(.offset_minutes))]}' "${JOBS}" >"${der}"
budget "${der}"
first_cron="$(sed -n 's/.*  \([0-9,]*\) \* \* \* \*.*/\1/p' "${ROOT}/budget.log" | head -1)"
budget "${der}"
assert_eq "a derived offset is stable across runs" "${first_cron}" \
    "$(sed -n 's/.*  \([0-9,]*\) \* \* \* \*.*/\1/p' "${ROOT}/budget.log" | head -1)"
assert_eq "and it is a real offset, not empty" 4 "$(awk -F, '{print NF}' <<<"${first_cron}")"

# Two repositories, no offsets: the derivation has to separate them rather than stack
# them on one minute. This is the staggering the fleet used to get by hand.
spread="${ROOT}/spread.json"
jq '{jobs: [(.jobs[0] | .ticks_per_hour = 2 | del(.offset_minutes)),
            (.jobs[0] | .repo = "XRPLF/other" | .ticks_per_hour = 2 | del(.offset_minutes))]}' \
    "${JOBS}" >"${spread}"
budget "${spread}"
assert_eq "exit status is 0" 0 "${rc}"
crons="$(sed -n 's/.*  \([0-9,]*\) \* \* \* \*.*/\1/p' "${ROOT}/budget.log")"
assert_eq "two repositories get two different offsets" 2 \
    "$(sort -u <<<"${crons}" | grep -c .)"

printf '\n== the job list is validated as a schema, not just as arithmetic ==\n'
# Every one of these deploys cleanly today if it is not caught here, and two of them
# are failures the bot cannot detect at run time: two jobs on one repo silently starve
# each other, and a name without the prefix is invisible to every alert filter.
for spec in \
    'duplicate name:{jobs: [.jobs[0], .jobs[0]]}' \
    'duplicate repo:{jobs: [.jobs[0], (.jobs[0] | .name = "copilot-review-bot-b")]}' \
    'name without the required prefix:.jobs[0].name = "bot-clio"' \
    'missing max_requests_per_run:del(.jobs[0].max_requests_per_run)' \
    'repo that is not owner/name:.jobs[0].repo = "rippled"' \
    'an @ in a value:.jobs[0].schedule = "a@DRY_RUN=true"' \
    'dry_run that is not a boolean:.jobs[0].dry_run = "yes"' \
    'run_deadline_seconds above task_timeout:.jobs[0].run_deadline_seconds = 1200' \
    'task_timeout above lock_ttl_minutes:.jobs[0].task_timeout = "30m"' \
    'an unparseable task_timeout:.jobs[0].task_timeout = "banana"' \
    'a memory value with no unit:.jobs[0].memory = "512"' \
    'a memory value with an unsupported unit:.jobs[0].memory = "512Ki"' \
    'jobs that is not an array:.jobs = "nope"'; do
    what="${spec%%:*}"
    patch="${spec#*:}"
    broken="${ROOT}/broken.json"
    jq "${patch}" "${JOBS}" >"${broken}"
    budget "${broken}"
    assert_eq "${what} is refused" 2 "${rc}"
done

printf '\n== a malformed budget entry is refused ==\n'
for patch in '.jobs[0].expected_open_prs = "many"' 'del(.jobs[0].expected_open_prs)' \
    'del(.jobs[0].ticks_per_hour)' '{jobs: []}'; do
    broken="${ROOT}/broken.json"
    jq "${patch}" "${JOBS}" >"${broken}"
    budget "${broken}"
    assert_eq "'${patch}' is exit 2" 2 "${rc}"
done

printf '\n== a timeout order that leaves room is accepted ==\n'
# The ordering the bot needs: it stops on its own terms before the platform kills it,
# and the lock outlives a killed task only briefly.
okorder="${ROOT}/okorder.json"
jq '.jobs[0] |= (.run_deadline_seconds = 700 | .task_timeout = "20m"
    | .lock_ttl_minutes = 25)' "${JOBS}" >"${okorder}"
budget "${okorder}"
assert_eq "700s < 20m < 25m is accepted" 0 "${rc}"

printf '\n== its own arguments are checked before anything else ==\n'
rc=0
env -i PATH="${TOOL_PATH}" HOME="${ROOT}" \
    "${BASH}" "${BUDGET}" "${ROOT}/no-such-file.json" \
    >"${ROOT}/budget.log" 2>"${ROOT}/budget.err" || rc=$?
assert_eq "an unreadable jobs file is exit 2" 2 "${rc}"
assert_contains "and it says which" "no-such-file.json" "$(cat "${ROOT}/budget.err")"

notjson="${ROOT}/notjson.json"
printf 'this is not json\n' >"${notjson}"
budget "${notjson}"
assert_eq "a file that is not JSON is exit 2" 2 "${rc}"
assert_contains "and it says so" "not valid JSON" "$(cat "${ROOT}/budget.err")"

# A PATH with dirname but no jq, so the script reaches its own jq guard rather than
# dying on the `dirname` in its second line. That is the shape a stripped-down image
# has, and the guard exists so the failure names the missing program.
mkdir -p "${ROOT}/nojq"
ln -sf "$(command -v dirname)" "${ROOT}/nojq/dirname"
rc=0
env -i PATH="${ROOT}/nojq" HOME="${ROOT}" \
    "${BASH}" "${BUDGET}" "${JOBS}" \
    >"${ROOT}/budget.log" 2>"${ROOT}/budget.err" || rc=$?
assert_eq "a missing jq is exit 2" 2 "${rc}"
assert_contains "and it names jq" "jq is required" "$(cat "${ROOT}/budget.err")"

printf '\n== the checked-in jobs.json passes its own check ==\n'
# The one that matters on every push: whatever is in the repository has to be
# deployable, or the pipeline fails after the image is already built and pushed.
budget "${DEPLOY_DIR}/jobs.json"
assert_eq "exit status is 0" 0 "${rc}"

printf '\n== and deploy-job.sh accepts the checked-in jobs.json too ==\n'
# rate-budget.sh validating the file is not the same as deploy-job.sh being able to
# deploy from it. Without this, a field only deploy-job.sh reads could be missing and
# the pipeline would fail after the image was built and pushed.
: >"${ROOT}/calls.log"
rc=0
env -i PATH="${TOOL_PATH}" HOME="${ROOT}" CALLS="${ROOT}/calls.log" \
    FAKE_DIR="${ROOT}" GCLOUD="${FAKE}" IMAGE=registry/crb@sha256:abc \
    PROJECT=xrplf-automation REGION=us-central1 BUCKET=state-bucket \
    "${BASH}" "${DEPLOY}" XRPLF/rippled "${DEPLOY_DIR}/jobs.json" \
    >"${ROOT}/out.log" 2>"${ROOT}/err.log" || rc=$?
LAST_LOG="${ROOT}/out.log"
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "it reached both gcloud calls" 2 \
    "$(grep -c -E '^(run|scheduler) jobs (create|update)' "${ROOT}/calls.log")"

summary

#!/usr/bin/env bash
#
# entrypoint-test.sh - drive deploy/entrypoint.sh against a stub bot and assert on
# what it passed through, and what it exited with.
#
# The entrypoint is the only thing between the schedule and the bot, so a mistake
# in it means no bot ran at all, or one ran with the wrong flags. What it can get
# wrong is the flag mapping and the argument order.
#
# No network and no GitHub token: BOT points at a stub on disk.
#
# Usage: ./entrypoint-test.sh [path-to-entrypoint.sh]
#
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test-lib.sh
. "${SUITE_DIR}/test-lib.sh"

ENTRYPOINT="${1:-${SUITE_DIR}/../deploy/entrypoint.sh}"
[[ -x "${ENTRYPOINT}" ]] || {
    echo "cannot execute ${ENTRYPOINT}" >&2
    exit 2
}
require_tools jq

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

# ---------------------------------------------------------------------------
# A stub bot that reports the arguments it was given. Shaped like the real bot's
# first line, so assert_log_shape covers the whole stream rather than only the
# entrypoint's half of it.
# ---------------------------------------------------------------------------
STUB="${ROOT}/copilot-review-bot.sh"
cat >"${STUB}" <<'BOT'
#!/usr/bin/env bash
# argc as well as args, because "$*" flattens argv: --base "release branch" and
# --base release branch produce the same string, so args alone cannot tell a
# correctly quoted "$@" from a bare $@. argc is the only thing that can.
printf '{"time":"%s","severity":"INFO","event":"stub.bot","args":"%s","argc":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" "$#"
BOT
chmod +x "${STUB}"

# run [args...] -> ${rc}, stdout in ${ROOT}/out.log, stderr in ${ROOT}/err.log
#
# env -i, so a DRY_RUN or VERBOSE already exported in the developer's shell cannot
# decide the result of a case that says nothing about it.
run() {
    rc=0
    # No extra binaries to locate: the stub bot needs only date and printf, and
    # build_tool_path already covers both.
    # shellcheck disable=SC2119
    env -i \
        PATH="$(build_tool_path)" \
        HOME="${ROOT}" \
        BOT="${STUB}" \
        GH_TOKEN=stub-token \
        REPO=XRPLF/rippled \
        ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
        "${BASH}" "${ENTRYPOINT}" "$@" >"${ROOT}/out.log" 2>"${ROOT}/err.log" || rc=$?
    LAST_LOG="${ROOT}/out.log"
    RUN_ENV=()
}
RUN_ENV=()

# ===========================================================================
printf '\n== by default the bot runs with no flags ==\n'
# Neither DRY_RUN nor VERBOSE set. An unset DRY_RUN must not become --dry-run, or
# a job created without it would silently never file anything.
run
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the bot ran with an empty argument list" 1 \
    "$(events "${ROOT}/out.log" '.event=="stub.bot" and .args==""')"
assert_eq "nothing was written to stderr" "" "$(cat "${ROOT}/err.log")"
assert_log_shape "${ROOT}/out.log" defaults

# ===========================================================================
printf '\n== DRY_RUN=true becomes --dry-run ==\n'
RUN_ENV=(DRY_RUN=true)
run
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "only --dry-run is added" 1 \
    "$(events "${ROOT}/out.log" '.event=="stub.bot" and .args=="--dry-run"')"

# ===========================================================================
printf '\n== VERBOSE=true becomes --verbose ==\n'
RUN_ENV=(VERBOSE=true)
run
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "only --verbose is added" 1 \
    "$(events "${ROOT}/out.log" '.event=="stub.bot" and .args=="--verbose"')"

# ===========================================================================
printf '\n== "false" is off, and anything else is refused ==\n'
# Refusing rather than defaulting, because the failure direction is otherwise wrong:
# DRY_RUN=1 would read as "not a dry run" and file real review requests, so somebody
# setting what they believe is a safety flag would get live mutations with nothing
# saying the value was not understood.
RUN_ENV=(DRY_RUN=false VERBOSE=false)
run
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "neither flag is added" 1 \
    "$(events "${ROOT}/out.log" '.event=="stub.bot" and .args==""')"

# An empty value is not in this list: ${DRY_RUN:-false} substitutes the default for
# unset and empty alike, so an empty setting means off, which is the same convention
# the bot uses for its own options.
for bad in 1 yes on True TRUE 0 "not true"; do
    RUN_ENV=(DRY_RUN="${bad}")
    run
    assert_eq "DRY_RUN='${bad}' is exit 2" 2 "${rc}"
    assert_eq "DRY_RUN='${bad}' names the setting" 1 \
        "$(events "${ROOT}/out.log" '.event=="entrypoint.bad_setting" and .setting=="DRY_RUN"')"
    assert_eq "DRY_RUN='${bad}' never ran the bot" 0 \
        "$(events "${ROOT}/out.log" '.event=="stub.bot"')"
done
RUN_ENV=(VERBOSE=maybe)
run
assert_eq "VERBOSE='maybe' is exit 2" 2 "${rc}"
assert_eq "and it names VERBOSE" 1 \
    "$(events "${ROOT}/out.log" '.event=="entrypoint.bad_setting" and .setting=="VERBOSE"')"
assert_log_shape "${ROOT}/out.log" bad_setting

# ===========================================================================
printf '\n== arguments reach the bot, so gcloud --args works ==\n'
# --pr, --base and --explain have no environment equivalent, so without this the
# "run it once by hand" step in the deploy runbook cannot be done on the platform.
run --pr 8080 --verbose
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the bot was given the arguments verbatim" 1 \
    "$(events "${ROOT}/out.log" '.event=="stub.bot" and .args=="--pr 8080 --verbose" and .argc==3')"

# ===========================================================================
printf '\n== flags come first, so an argument can override the job setting ==\n'
RUN_ENV=(DRY_RUN=true VERBOSE=true)
run --pr 42
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "both flags precede the argument" 1 \
    "$(events "${ROOT}/out.log" '.event=="stub.bot" and .args=="--dry-run --verbose --pr 42" and .argc==4')"

# ===========================================================================
printf '\n== an argument containing spaces survives as one argument ==\n'
# "$@" rather than $@. Without the quotes a --base with a space in it would arrive
# as two arguments and the bot would reject the second as unknown.
#
# Asserted on argc, not on args: "$*" renders both cases as the same string, so an
# args-only assertion passes against a bare $@ and this case proves nothing. Verified
# by breaking the entrypoint on purpose - argc catches it, args does not.
run --base 'release branch'
assert_eq "exit status is 0" 0 "${rc}"
assert_eq "the argument was not split" 1 \
    "$(events "${ROOT}/out.log" '.event=="stub.bot" and .args=="--base release branch" and .argc==2')"

# ===========================================================================
printf '\n== an image with no bot is one findable event, not a bare exec error ==\n'
RUN_ENV=(BOT="${ROOT}/not-a-bot")
run
assert_eq "exit status is 2, the fatal code" 2 "${rc}"
assert_eq "it reported the failure as an event" 1 \
    "$(events "${ROOT}/out.log" '.event=="entrypoint.bot_missing" and .severity=="ERROR"')"
assert_eq "the stub never ran" 0 "$(events "${ROOT}/out.log" '.event=="stub.bot"')"
assert_eq "nothing was written to stderr" "" "$(cat "${ROOT}/err.log")"
assert_log_shape "${ROOT}/out.log" bot_missing

# ===========================================================================
printf '\n== a bot that is present but not executable is the same event ==\n'
printf 'not executable\n' >"${ROOT}/unreadable-bot"
chmod 0644 "${ROOT}/unreadable-bot"
RUN_ENV=(BOT="${ROOT}/unreadable-bot")
run
assert_eq "exit status is 2" 2 "${rc}"
assert_eq "it reported the same event" 1 \
    "$(events "${ROOT}/out.log" '.event=="entrypoint.bot_missing"')"

# ===========================================================================
printf '\n== the bot exit status is the entrypoint exit status ==\n'
# exec, not a call, so Cloud Run marks the execution failed on the bot's own code.
# The runbook alerts on that, so a swallowed non-zero would read as a green no-op.
cat >"${ROOT}/failing-bot" <<'BOT'
#!/usr/bin/env bash
printf '{"time":"%s","severity":"ERROR","event":"stub.bot","args":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
exit 1
BOT
chmod +x "${ROOT}/failing-bot"
RUN_ENV=(BOT="${ROOT}/failing-bot")
run
assert_eq "the bot's exit 1 is passed through" 1 "${rc}"

summary

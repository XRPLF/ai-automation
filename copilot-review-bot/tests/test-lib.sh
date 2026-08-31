# shellcheck shell=bash
#
# test-lib.sh - shared harness for the five copilot-review-bot test suites.
#
# Sourced, never executed. It holds what all five need identically: the bash floor,
# locating the script under test, building a PATH that a stub cannot be bypassed on,
# the assertions, and the summary.
#
# It sits beside its five consumers, so every suite sources it the same way:
# `. "${SUITE_DIR}/test-lib.sh"`.
#
# calls() and events() take the file to read as their first argument, so every suite
# calls them the same way.

# bash 4.4 is the floor for the same reason the bot needs it: "${empty[@]}" under
# `set -u`. Checked here too, because a suite that dies on its own harness is
# harder to diagnose than one that says why.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    echo "bash 4.4+ required (this is ${BASH_VERSION:-unknown} at ${BASH})" >&2
    exit 2
fi

pass=0
fail=0

# The log the current scenario produced. Suites set it in their run() so that a
# failure can show what the bot actually did, instead of only the assertion that
# noticed. Printed when SUITE_VERBOSE is set, or automatically on a GitHub Actions
# run re-run with debug logging, which sets RUNNER_DEBUG.
LAST_LOG=""

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
ok() { # <what>
    printf '  ok   %s\n' "$1"
    pass=$((pass + 1))
}

bad() { # <what> <detail>
    printf '  FAIL %s\n       %s\n' "$1" "$2"
    fail=$((fail + 1))
    if [[ -n "${SUITE_VERBOSE:-${RUNNER_DEBUG:-}}" && -s "${LAST_LOG}" ]]; then
        printf '       --- %s ---\n' "${LAST_LOG}"
        sed 's/^/       | /' "${LAST_LOG}"
    fi
}

assert_eq() { # <what> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        ok "$1"
    else
        bad "$1" "expected '$2', got '$3'"
    fi
}

assert_contains() { # <what> <needle> <haystack>
    if [[ "$3" == *"$2"* ]]; then
        ok "$1"
    else
        bad "$1" "expected to contain '$2', got '$3'"
    fi
}

# ---------------------------------------------------------------------------
# Locating the bot and its tools
# ---------------------------------------------------------------------------
# Absolute path to the script under test, so a suite can cd freely afterwards. The
# first argument is the directory holding the bot, which is the tool directory rather
# than the suite's own: the suites live one level down, in tests/.
resolve_bot() { # <tool-dir> [override-path]
    local b="${2:-$1/copilot-review-bot.sh}"
    [[ -x "${b}" ]] || {
        echo "cannot execute ${b}" >&2
        exit 2
    }
    printf '%s/%s' "$(cd "$(dirname "${b}")" && pwd)" "$(basename "${b}")"
}

require_tools() { # <binary>...
    local b
    for b in "$@"; do
        command -v "${b}" >/dev/null || {
            echo "${b} is required" >&2
            exit 2
        }
    done
}

# PATH for a run, rebuilt from scratch so the stub gh cannot be bypassed. On
# macOS a modern bash, jq and flock are not in the system directories, so each
# tool is located rather than assumed. timeout is in the default list because the
# bot wraps every gh call in it, and without it the bot warns instead, which
# would show up as an unexpected log line.
build_tool_path() { # [extra-binary...]
    local p b d
    p="$(dirname "${BASH}")"
    for b in jq sed grep tr head tail mktemp date uname timeout "$@"; do
        d="$(dirname "$(command -v "${b}" 2>/dev/null || echo /usr/bin/true)")"
        case ":${p}:" in
            *":${d}:"*) ;;
            *) p="${p}:${d}" ;;
        esac
    done
    printf '%s' "${p}"
}

# ---------------------------------------------------------------------------
# Reading what a run did
# ---------------------------------------------------------------------------
# How many calls of a kind the stub recorded. The stub writes one tab-separated
# line per call, so the prefix is the call kind.
calls() { # <calls-log> <prefix>
    grep -c "^$2" "$1" 2>/dev/null || true
}

# How many log lines satisfy a jq predicate. Prints JSON-PARSE-ERROR rather than
# 0 when the log is not all JSON, so a malformed line fails the assertion it
# appears in instead of silently reading as "none matched".
events() { # <out-log> <jq-predicate>
    jq -s "[.[] | select($2)] | length" "$1" 2>/dev/null || printf 'JSON-PARSE-ERROR'
}

# Every line has to be one JSON object with a severity Cloud Logging recognizes
# and a time, because that is the whole contract the deploy runbook filters on.
assert_log_shape() { # <out-log> <label>
    local log="$1" label="$2" n bad_sev no_time
    n="$(wc -l <"${log}" | tr -d ' ')"
    if ! jq -e . "${log}" >/dev/null 2>&1; then
        bad "${label}: every log line is JSON" "$(head -3 "${log}")"
        return
    fi
    bad_sev="$(jq -s '[.[] | select((.severity // "") as $s
        | ["DEBUG","INFO","NOTICE","WARNING","ERROR","CRITICAL","ALERT","EMERGENCY"]
        | index($s) == null)] | length' "${log}")"
    if ((n > 0)) && [[ "${bad_sev}" == 0 ]]; then
        ok "${label}: ${n} log line(s), all JSON with a known severity"
    else
        bad "${label}: log shape" "lines=${n} bad_severity=${bad_sev}"
    fi
    no_time="$(jq -s '[.[] | select(.time == null)] | length' "${log}")"
    assert_eq "${label}: every line carries a time" 0 "${no_time}"
}

summary() {
    printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
    ((fail == 0)) || exit 1
}

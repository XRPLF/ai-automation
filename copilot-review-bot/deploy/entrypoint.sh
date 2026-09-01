#!/usr/bin/env bash
# Cloud Run Job entrypoint: run the baked-in bot once.
#
# The bot is part of the image, so there is nothing to fetch and nothing to check
# out. What CI built is what runs, and a rollback is pointing the job at an older
# image tag. This file exists only to turn two job settings into flags, and to keep
# `gcloud run jobs execute --args` reaching the bot.
#
# Environment:
#   GH_TOKEN   (required) GitHub token, injected from Secret Manager.
#   REPO       (required) the one repo to watch, owner/name. Read by the bot, not
#              by this file.
#   DRY_RUN    "true" adds --dry-run. Anything but true or false is refused.
#   VERBOSE    "true" adds --verbose. Anything but true or false is refused.
#   BOT        path to the bot. Overridable only so entrypoint-test.sh can drive a
#              stub, the same reason the bot has GITHUB_API_ROOT.
#
# Arguments are passed through, so `gcloud run jobs execute --args=--pr,8080`
# reaches the bot: --pr, --base and --explain have no environment equivalent. They
# come after the flags below, so an argument wins over the job's own setting.
set -Eeuo pipefail

BOT="${BOT:-/app/copilot-review-bot.sh}"

# One JSON object per line, on stdout, because that is the bot's own log contract
# and the deploy runbook filters on it. A bare exec failure would instead print
# "no such file or directory" to stderr, where no `event` filter matches it.
[[ -x "${BOT}" ]] || {
    printf '{"time":"%s","severity":"ERROR","event":"entrypoint.bot_missing","message":"the image carries no executable bot, so no run happened","path":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${BOT}"
    exit 2
}

# Refused rather than defaulted, because the failure direction is wrong otherwise:
# DRY_RUN=1 or DRY_RUN=yes would read as "not a dry run" and file real review
# requests, so somebody setting what they believe is a safety flag would get live
# mutations with nothing saying the value was not understood. deploy-job.sh rejects
# the same values at deploy time; this is the gate for a job whose environment was
# changed by hand afterwards.
# Called at the top level, never inside $( ), so the event reaches stdout and the
# exit ends the run rather than a subshell.
require_boolean() { # <name> <value>
    case "$2" in
        true | false) return 0 ;;
    esac
    printf '{"time":"%s","severity":"ERROR","event":"entrypoint.bad_setting","message":"%s must be true or false, so no run happened","setting":"%s","given":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$1" "$2"
    exit 2
}

require_boolean DRY_RUN "${DRY_RUN:-false}"
require_boolean VERBOSE "${VERBOSE:-false}"

args=()
[[ "${DRY_RUN:-false}" == "true" ]] && args+=(--dry-run)
[[ "${VERBOSE:-false}" == "true" ]] && args+=(--verbose)

exec "${BOT}" ${args[@]+"${args[@]}"} "$@"

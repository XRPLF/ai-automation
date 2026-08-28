#!/usr/bin/env bash
# Cloud Run Job entrypoint: fetch the latest bot from main, then run it once.
#
# Environment:
#   GH_TOKEN   (required) GitHub token, injected from Secret Manager.
#   REPOS      (required) whitespace-separated repos to watch, read by the bot.
#   REPO_URL   where to fetch the bot from. Default: this repo on GitHub.
#   REPO_REF   branch or tag to fetch. Default: main.
#   DRY_RUN    "true" adds --dry-run.
#   VERBOSE    "true" adds --verbose.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/XRPLF/ai-automation}"
REPO_REF="${REPO_REF:-main}"

workdir="$(mktemp -d)"
git clone --quiet --depth 1 --branch "${REPO_REF}" "${REPO_URL}" "${workdir}/src"
echo "running copilot-review-bot @ $(git -C "${workdir}/src" rev-parse --short HEAD) (${REPO_REF})"

args=()
[[ "${DRY_RUN:-false}" == "true" ]] && args+=(--dry-run)
[[ "${VERBOSE:-false}" == "true" ]] && args+=(--verbose)

cd "${workdir}/src/copilot-review-bot"
exec ./copilot-review-bot.sh ${args[@]+"${args[@]}"}

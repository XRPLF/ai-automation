#!/usr/bin/env bash
# Cloud Run Job entrypoint: fetch the latest bot from main, then run it once.
#
# Environment:
#   GH_TOKEN   (required) GitHub token, injected from Secret Manager.
#   REPOS      (required) whitespace-separated repos to watch, read by the bot.
#   REPO       owner/name to fetch the bot from. Default: XRPLF/ai-automation.
#   REPO_REF   branch or tag to fetch. Default: main.
#   DRY_RUN    "true" adds --dry-run.
#   VERBOSE    "true" adds --verbose.
set -euo pipefail

REPO="${REPO:-XRPLF/ai-automation}"
REPO_REF="${REPO_REF:-main}"

# gh clones with GH_TOKEN, which also covers a private repo.
workdir="$(mktemp -d)"
gh repo clone "${REPO}" "${workdir}/src" -- --quiet --depth 1 --branch "${REPO_REF}"
echo "running copilot-review-bot @ $(git -C "${workdir}/src" rev-parse --short HEAD) (${REPO_REF})"

args=()
[[ "${DRY_RUN:-false}" == "true" ]] && args+=(--dry-run)
[[ "${VERBOSE:-false}" == "true" ]] && args+=(--verbose)

cd "${workdir}/src/copilot-review-bot"
exec ./copilot-review-bot.sh ${args[@]+"${args[@]}"}

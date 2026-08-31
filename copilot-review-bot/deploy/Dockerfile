# Runtime image for copilot-review-bot on Cloud Run Jobs. The bot is baked in, so
# the image is the whole deployment: what CI built is what runs, and a rollback is
# pointing the job back at an older digest. Nothing is fetched at run time.
#
# Build from the tool directory, not from this one, because the bot lives one level up
# and both COPY paths below are relative to that:
#
#     docker build -f copilot-review-bot/deploy/Dockerfile -t copilot-review-bot \
#         copilot-review-bot
#
# The context is the tool directory rather than the repository, so nothing belonging to
# another tool, and no .git, is ever sent to the daemon. copilot-review-bot/.dockerignore
# pares that context down to the two files COPYed here: it is the context root's own ignore
# file, which is one level above this Dockerfile, and Docker reads it from the context rather
# than from beside the Dockerfile.
#
# trixie rather than bookworm, for jq. bookworm ships jq 1.6, which recompiles its
# builtin library on every invocation: 17.7ms against a 0.4ms process floor. The bot
# runs jq three times per pull request, so at 300 PRs that was 16s of pure interpreter
# startup and 87% of the bot's CPU time. trixie ships 1.7, which precompiles.
#
# The base tag floats and the packages are unversioned, so the same commit built twice
# can carry different tool versions. That is deliberate: every merge rebuilds, so a
# floating base is how this image gets security updates. What CI guarantees is
# narrower, and it is the part that matters - the `sha256sum` gate in
# copilot-review-bot.yml proves the *bot* in the image matches the commit.
#
# coreutils and util-linux are Priority: required in Debian, so timeout(1), which
# bounds every gh call, and flock arrive without an install line. The smoke test in CI
# runs every program the bot needs with --version, because that assumption is the one
# thing here nothing else would catch.
#
# git is present because the Debian `gh` package declares `Depends: git`, which
# --no-install-recommends does not drop. Nothing calls it. Do not remove it: that
# breaks gh.
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 copilot-review-bot.sh /app/copilot-review-bot.sh
COPY --chmod=0755 deploy/entrypoint.sh /entrypoint.sh
RUN useradd --create-home bot

USER bot
ENV HOME=/home/bot

# STATE_DIR is deliberately NOT set here. It has to be a gs:// URL, because a
# Cloud Run execution gets a fresh filesystem and any local path silently loses the
# head-commit markers every run. The job sets it; the bot warns on every run if it is
# missing or local. See ./README.md.

ENTRYPOINT ["/entrypoint.sh"]

# Runtime image for copilot-review-bot on Cloud Run Jobs. The bot itself is
# NOT baked in: the entrypoint clones the latest main of this repo at the start
# of every run, so merging a bot change deploys it without a rebuild. This
# image only pins the tools the bot needs (bash 5, gh, jq, git, flock).
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git jq util-linux \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh && useradd --create-home bot

USER bot
ENV STATE_DIR=/tmp/state

ENTRYPOINT ["/entrypoint.sh"]

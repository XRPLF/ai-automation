# copilot-review-bot

A polling bot that keeps GitHub Copilot reviews flowing on one or more repos.
One Bash script, `gh` + `jq`, run from a systemd timer every ~15 minutes. No
inbound connections, no webhook receiver, no database — which is what makes it
fit a Google Cloud VM that can only talk outbound.

Files:

| File | Purpose |
| --- | --- |
| `copilot-review-bot.sh` | The whole application. |
| `copilot-review-bot.service` / `.timer` | systemd units for the 15-minute cadence. |
| `copilot-review-bot-test.sh` | Offline tests for the decision rules (no token needed). |

## Why polling, and why one process for all repos

Webhooks would need an inbound port; the VM does not have one. So every run is
a fresh read of current state, and every decision is derived from GitHub rather
than from remembered history. That has a pleasant side effect: the bot is
idempotent and crash-safe. If a run dies halfway, or the VM is rebuilt, the
next run reaches the same conclusions.

One process handles every repo (`--repo` is repeatable, or set `$REPOS`). That
keeps a single token, a single lock and a single rate-limit budget. Running
one instance per repo also works if you prefer isolation — pass different
`STATE_DIR` and `LOCK_FILE` values so they don't share a lock.

## Prerequisites

Checked before any work starts, with an install hint per missing item, so a
missing dependency never turns a scheduled run into a silent no-op:

* **bash 4.4+** — earlier versions treat `"${empty_array[@]}"` as an unbound
  variable under `set -u`. macOS still ships 3.2 as `/bin/bash`, so use a newer
  one (`brew install bash`) and make sure it wins on `PATH`.
* **gh** — authenticated via `GH_TOKEN` / `GITHUB_TOKEN`.
* **jq**.
* **flock** — from `util-linux` on Linux, `brew install flock` on macOS.
* **date** — GNU or BSD; the flavour is probed at startup.

## Decision rules

**Automatic requests** — only for PRs that are open, not draft, and target the
repo's base branch (its default branch, or `--base BRANCH`):

| Situation | Action |
| --- | --- |
| Copilot has never reviewed the PR | request a review |
| Copilot reviewed; all its threads resolved; ≥1 non-merge commit since the reviewed commit | request a review |
| Copilot reviewed; any of its threads still unresolved | wait |
| Copilot reviewed; only merge commits since (branch refreshed from base) | wait |
| Copilot reviewed the current head commit | wait |
| A Copilot review request is already pending | wait |

"Non-merge" means the commit has exactly one parent, so pulling the base branch
into the PR branch never triggers a new review, while any real commit does.
Only threads **opened by Copilot** count toward "resolved"; human review threads
are ignored.

### How "new work" is established

The commit Copilot reviewed is the anchor, and there are three cases. The log
line says which one fired, so a wrong call is auditable without re-deriving it.

| `basis` | When | Test |
| --- | --- | --- |
| `position` | The reviewed commit is still on the branch | Anything after it with one parent is new work. Exact. |
| `authored` | The branch was rewritten, and something on it was **authored** after the review | Those commits are new work. |
| `rewritten` | The branch was rewritten and nothing on it was authored after the review | A restack or an amend. Governed by `REWRITE_TRIGGERS_REVIEW` (default `false`: wait). |

The author/committer distinction is the crux. A rebase stamps every commit it
moves with a fresh **committer** date while leaving the **author** date alone.
Keying on committer dates therefore reports the very commit Copilot already
reviewed as brand new, and every restack triggers a fresh review — which is
what a real PR in `XRPLF/rippled` was doing: a commit authored Aug 2, reviewed
Aug 3, restacked Aug 25 came back as "new since the review". Author dates make
the restack case answerable.

The residual ambiguity is `rewritten`. `git commit --amend` keeps the original
author date, so an amend carrying real work is indistinguishable from a pure
restack using metadata alone. The default waits rather than re-reviewing on
every rebase; anyone who disagrees in a specific case can `@xrplf-bot` the PR,
and setting `REWRITE_TRIGGERS_REVIEW=true` inverts the default globally.

**Mentions** — a comment mentioning `@xrplf-bot` (configurable with
`--handle`) triggers a request on *any* open PR, including drafts and PRs
targeting other branches. Both PR conversation comments and inline review
comments are scanned. The bot then reacts to the comment that asked:

| Reaction | Meaning |
| --- | --- |
| 👍 `THUMBS_UP` | Copilot review requested |
| 👎 `THUMBS_DOWN` | request failed — the error code and message are also posted as a PR comment, since a reaction cannot carry one |
| 👀 `EYES` | acknowledged, nothing to do: Copilot already reviewed the current head commit, or a request is already pending |

The reaction doubles as the bookkeeping. A comment already carrying one of
those three reactions *from the bot's own account* is skipped forever after, so
no local state is needed to avoid answering twice — and the same holds after a
VM rebuild. A 👍 from a human does not count. Mentions inside quoted lines
(`> @xrplf-bot ...`) are ignored, so quoting a request does not re-fire it,
and the bot ignores its own comments.

## Install on a GCP VM (Debian/Ubuntu)

Run these from inside this `copilot-review-bot/` directory — the commands
below reference `copilot-review-bot.sh`, `README.md`, and the `.service` /
`.timer` files by bare name.

```bash
# 1. Dependencies. gh comes from GitHub's apt repo.
sudo apt-get update && sudo apt-get install -y jq curl ca-certificates util-linux
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
sudo apt-get update && sudo apt-get install -y gh

# 2. Unprivileged service account and layout.
sudo useradd --system --home /var/lib/copilot-review-bot --shell /usr/sbin/nologin copilot-bot
sudo install -d -o copilot-bot -g copilot-bot -m 0750 /var/lib/copilot-review-bot
sudo install -d -m 0755 /opt/copilot-review-bot /etc/copilot-review-bot
sudo install -m 0755 copilot-review-bot.sh /opt/copilot-review-bot/
sudo install -m 0644 README.md /opt/copilot-review-bot/

# 3. Token and repo list. Keeping the token in a file rather than the unit
#    keeps it out of the process table and out of `systemctl cat`.
sudo tee /etc/copilot-review-bot/env >/dev/null <<'EOF'
GH_TOKEN=ghp_replace_me
REPOS="XRPLF/rippled XRPLF/clio"
EOF
sudo chown copilot-bot:copilot-bot /etc/copilot-review-bot/env
sudo chmod 0600 /etc/copilot-review-bot/env

# 4. Timer.
sudo install -m 0644 copilot-review-bot.service copilot-review-bot.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now copilot-review-bot.timer
```

Check it:

```bash
systemctl list-timers copilot-review-bot.timer
sudo systemctl start copilot-review-bot.service     # run once, now
journalctl -u copilot-review-bot.service -n 100 --no-pager
```

Prefer cron? The script is a plain one-shot, so this is equivalent:

```cron
*/15 * * * * GH_TOKEN=ghp_... STATE_DIR=$HOME/.local/state/copilot-review-bot \
  /opt/copilot-review-bot/copilot-review-bot.sh XRPLF/rippled XRPLF/clio \
  >> /var/log/copilot-review-bot.log 2>&1
```

Egress: only `api.github.com` over 443 is needed at runtime (plus your distro
mirrors for updates). No ingress rules, no external IP required if the VM has
Cloud NAT.

## Token permissions

The account behind the token needs at least the **Triage** repo role — the
floor GitHub requires for requesting a review from a human collaborator,
because Copilot occupies the same "Reviewers" slot. The token itself also needs
write access, or the `requestReviews` mutation 403s even when the user's role
would allow it:

* **Fine-grained PAT**: `Pull requests: Read and write` (Metadata: Read is
  attached automatically). `Contents: Read` is recommended so commit parents
  are readable on private repos.
* **Classic PAT**: `repo`, or `public_repo` if every watched repo is public.
* **GitHub App installation token**: `Pull requests: write`. Reactions and
  comments are posted as the app, which is the tidier option if you want the
  bot to have its own identity — note the `@handle` you configure must match
  whatever people actually type.

Read-only access is enough for the monitoring half but not for the mutation
that files the request. Separately, Copilot must have a licence/seat enabled
for the repo: without it the request is filed and simply never acted on, which
looks like the bot succeeding and Copilot ignoring it (because that is exactly
what happens).

## Copilot's bot node id

GitHub's REST "request reviewers" endpoint rejects bot accounts, so requests go
through the GraphQL `requestReviews` mutation with `botIds` — which needs
Copilot's `Bot` node id, and there is no lookup-by-login query for bots. The
script finds it in this order:

1. `--bot-id` / `COPILOT_BOT_ID`.
2. Cache file at `$STATE_DIR/copilot-bot-id`.
3. Scavenged for free from the PRs it just fetched (any prior Copilot review or
   pending request exposes the id), then cached.
4. A scan of the last 40 PRs of any state in that repo.
5. The well-known id `BOT_kgDOC9w8XQ`, with a warning. Set
   `USE_BOT_ID_HINT=false` to turn that fallback off, or pass `--bot-id` once
   and it is cached from then on.

## Options and environment

| Option | Env | Default | Notes |
| --- | --- | --- | --- |
| `--repo owner/name` | `REPOS` | — | Repeatable, and also accepted as bare arguments. `REPOS` is whitespace separated and used only when no repo is given on the command line. |
| `--base BRANCH` | — | repo default branch | Gate for automatic requests. |
| `--handle NAME` | `MENTION_HANDLE` | `xrplf-bot` | Without the `@`. |
| `--mention-age DAYS` | `MENTION_MAX_AGE_DAYS` | `7` | Ignore older comments. Keeps the first run from replying to years of history. |
| `--max-requests N` | `MAX_REQUESTS_PER_RUN` | `25` | Backlog is picked up on later runs. |
| `--ignore-outdated` | `IGNORE_OUTDATED` | `false` | Treat outdated Copilot threads as resolved. |
| `--pr N` | — | — | Debug a single PR. |
| `--bot-id ID` | `COPILOT_BOT_ID` | discovered | See above. |
| `-n, --dry-run` | — | — | Decide and log, change nothing. |
| `-v, --verbose` | — | — | Log every PR including skips, with the reason. |
| — | `STATE_DIR` | `$XDG_STATE_HOME/copilot-review-bot` | Bot-id cache, lock, head-commit markers. |
| — | `MAX_PRS_PER_REPO` | `300` | Cap on open PRs inspected per repo. |
| — | `SLEEP_BETWEEN_MUTATIONS` | `1` | Seconds; eases GitHub's secondary rate limits. |
| — | `PROGRESS_EVERY` | `25` | Heartbeat interval in PRs for non-verbose runs; `0` disables. Verbose runs log every PR instead. |
| — | `REWRITE_TRIGGERS_REVIEW` | `false` | Whether a force-push with nothing newly authored counts as new work. |
| — | `COPILOT_LOGINS` | JSON array | Logins treated as Copilot. |

Exit status: `0` clean, `1` at least one PR errored, `2` fatal — bad usage, a
missing prerequisite, or a lock that could not be taken.

### Running it on macOS

Fine for testing, with the caveats above: a Homebrew bash first on `PATH`, and
`brew install flock`. BSD `date` is handled. `STATE_DIR` defaults to
`~/.local/state/copilot-review-bot` there as on Linux.

## State on disk

Everything under `$STATE_DIR`:

* `copilot-bot-id` — cached node id.
* `lock` — `flock` target; a run that overlaps its predecessor exits quietly.
* `requested/<owner>__<name>__<pr>` — the head commit the last request was
  filed for. Belt-and-braces against a double request in the window before
  GitHub reports the pending review request. Files older than 90 days are
  pruned automatically.

Deleting `$STATE_DIR` is safe. Worst case the bot re-derives the bot id and may
re-file one request for a PR whose pending state has not yet materialised.

## Testing and debugging

```bash
./copilot-review-bot.sh --help                              # also runs no checks
./copilot-review-bot-test.sh                                # 19 offline cases, no token needed
./copilot-review-bot.sh -v -n --repo XRPLF/rippled          # dry run, full reasoning
./copilot-review-bot.sh -v --repo XRPLF/rippled --pr 8080   # one PR
```

`copilot-review-bot-test.sh` feeds synthetic PR payloads through the same jq
programs the live path uses (via the script's `--explain` mode), covering merge
vs non-merge commits, unresolved threads, all three `basis` paths (including
the restack regression, with the real author/committer dates from
`XRPLF/rippled#7941`), pending requests, and every mention case. Extend it
before changing the rules.

`--explain FILE` runs the rules over any saved `pullRequest` object, which is
handy for post-mortems on a PR that behaved unexpectedly: capture the object
once (the query lives in the `Q_PR` variable at the top of the script), save it
as `pr.json`, then `./copilot-review-bot.sh --explain pr.json`. It prints the
decision fields and the mentions it would answer, and touches nothing.

## Troubleshooting

Run with `-v --dry-run` first: verbose mode logs the raw `gh` error for every
failed query, plus the reasoning for every PR it skips.

**`cannot read repository` / `cannot list PRs`.** The script diagnoses this
itself, but the short version: a token that authenticates is not the same as a
token that can see the repo. Fine-grained PATs (`github_pat_...`) are
deny-by-default and can only reach repositories explicitly granted to them —
**public repositories included**. So a valid fine-grained PAT can fail on a
public repo that an anonymous client reads without trouble. Either select
"Public Repositories (read-only)" when creating it, or have it granted the repo
(which needs the organisation to permit fine-grained tokens *and* an owner to
approve), or use a classic PAT with `repo` / `public_repo`.

Check by hand:

```bash
gh api user --jq .login                  # is the token valid at all?
gh api repos/XRPLF/rippled --jq .full_name   # can it see the repo?
curl -sS -o /dev/null -w '%{http_code}\n' https://api.github.com/repos/XRPLF/rippled
                                         # what an anonymous client sees
```

If the first two disagree, it is the token's resource scoping, not the repo.
Reading is only half of it: filing requests also needs `Pull requests: Read and
write` and at least the Triage role.

**`another instance is running`.** A previous run still holds the lock, or is
wedged. `flock` releases on process exit, so a stale lock means a live process:
check with `systemctl status copilot-review-bot.service`.

## Cost and duration per run

Roughly `1 + N` GraphQL calls per repo for `N` open PRs, plus one mutation per
action. Against the 5,000 points/hour GraphQL limit, four runs an hour over
~100 open PRs is comfortable. Mutations are spaced by
`SLEEP_BETWEEN_MUTATIONS` and capped by `--max-requests` because GitHub's
*secondary* limits care about burst mutation rate, not points.

Calls are sequential, so wall-clock time is roughly one second per open PR:
`XRPLF/rippled` at ~265 open PRs takes about four to five minutes. That fits a
15-minute timer, and if a run ever does overrun the next tick, `flock` makes
the later run exit rather than double up. PRs are decided as they are fetched,
so output starts with the first PR — a run that prints nothing for minutes is
stuck, not working.

Every PR is fetched every run, deliberately. Filtering on `updatedAt` would be
the obvious economy, but resolving a review thread does not bump it, and
"Copilot's threads are now all resolved" is exactly one of the transitions that
has to be noticed.

## Known limitations

* **Amended commits.** See "How new work is established" above: an amend that
  carries real work looks exactly like a restack, because both preserve the
  author date. With the default `REWRITE_TRIGGERS_REVIEW=false` such a change
  waits for either a further commit or an `@xrplf-bot` mention.
* **Cherry-picks after a force-push.** A commit written before the review but
  cherry-picked onto a rewritten branch has an author date that predates the
  review, so it is not counted. With the anchor intact the positional test
  catches it correctly; only the rewritten-branch path is affected.
* **Commit window.** Only the most recent 100 commits of a PR are examined. A
  PR with more than 100 commits after the reviewed one falls back to the date
  comparison.
* **Outdated threads.** A Copilot thread whose code has since changed stays
  unresolved and keeps blocking, matching the letter of the rule. If your
  reviewers routinely leave those to rot, `--ignore-outdated` unblocks them.
* **Mention window.** Comments older than `--mention-age` days are never
  answered, so a mention that arrives while the bot is down for over a week is
  missed. Reactions, not timestamps, prevent duplicates — the window exists
  only to bound the first run.
* **PR cap.** `MAX_PRS_PER_REPO` (300) open PRs per repo, newest activity
  first.
* **PR list pagination.** The PR list is sorted by `updatedAt`, which can
  change while a repo with more than 100 open PRs is being paged through
  (each page is a separate GraphQL call). A PR updated at the wrong moment
  can shift past the page boundary and be missed for that run. Every run
  re-lists from scratch, so this self-heals on the next one; it only ever
  delays a decision, never permanently drops it.
* **Copilot cannot review its own trigger.** If Copilot is rate-limited or
  unlicensed, requests succeed and nothing happens; the bot has no way to
  distinguish that from a slow review, and will not re-request while the
  request stays pending.

# Deployment: GCP `xrplf-automation`

For the system administrator who has to grant access, and for whoever is on call when the bot stops
working. It covers what runs in production, who may change it, how to add a watched repository, and
what to do when a tick fails.

What the bot decides, and why, is in [../README.md](../README.md). How to test a change is in
[../tests/README.md](../tests/README.md). `run`, `tick`, `execution`, `fleet` and `state root` each
mean one thing throughout: see [Words used here](../README.md#words-used-here). In the commands
below, `<job>` is a `name` from [`jobs.json`](jobs.json) and `<owner>/<name>` is the repository that
job watches. Substitute both.

**Setting this up for the first time?** Start at [Set it up from scratch](#set-it-up-from-scratch),
which puts the eight steps in order and links to the section that explains each one.

## What runs in production

copilot-review-bot runs as **one Cloud Run job per watched repository** in the `xrplf-automation`
project. Each job has its own Cloud Scheduler job, called its tick. There is no VM, no inbound
endpoint, and nothing running between ticks.

Egress is `api.github.com` and `storage.googleapis.com` over 443. There is no ingress.

```mermaid
flowchart LR
    subgraph gh[GitHub]
        A[Actions<br/>copilot-review-bot.yml]
        API[api.github.com]
    end
    subgraph gcp[GCP project xrplf-automation]
        AR[Artifact Registry<br/>images/copilot-review-bot]
        SCH[Cloud Scheduler<br/>copilot-review-bot-&lt;owner&gt;-&lt;name&gt;-tick]
        JOB[Cloud Run job<br/>copilot-review-bot-&lt;owner&gt;-&lt;name&gt;]
        SM[Secret Manager<br/>gh-token]
        GCS[Cloud Storage<br/>state bucket]
        LOG[Cloud Logging<br/>and Monitoring]
    end
    A -- OIDC, acts as deployer --> AR
    A -- reconcile from jobs.json --> JOB
    A -- reconcile from jobs.json --> SCH
    SCH -- acts as scheduler-invoker --> JOB
    JOB -- pulls the pinned digest --> AR
    JOB -- acts as bot-runtime --> SM
    JOB -- lock and markers --> GCS
    JOB -- GH_TOKEN over 443 --> API
    JOB -- one JSON object per line --> LOG
```

Everything in this directory belongs to that one tool, which is why it sits inside
[`copilot-review-bot/`](../README.md) rather than at the repository root.

## The pieces

| Piece             | Name                                                                       | Purpose                                                                                                                                                                                                                                               |
| ----------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Job list          | [`jobs.json`](jobs.json)                                                   | Which repositories are watched, on what schedule. The source of truth: CI brings every listed job into line with it on every push. A job *removed* from the list is not deleted. See [Removing an entry](#removing-an-entry-does-not-remove-the-job). |
| Cloud Run job     | `copilot-review-bot-<owner>-<name>`                                        | One bot run per execution, in `us-central1`. One task, no retries.                                                                                                                                                                                    |
| Cloud Scheduler   | `copilot-review-bot-<owner>-<name>-tick`                                   | Executes its job on the schedule in `jobs.json`.                                                                                                                                                                                                      |
| Secret Manager    | `gh-token`                                                                 | The bot account's GitHub PAT, injected as `GH_TOKEN`.                                                                                                                                                                                                 |
| Cloud Storage     | `xrplf-copilot-review-bot-state`                                           | The lock and the head-commit markers, under `<owner>/<name>/`.                                                                                                                                                                                        |
| Artifact Registry | `images/copilot-review-bot`                                                | Runtime image: Debian, bash 5, `gh`, `jq`, `curl`, **and the bot itself**.                                                                                                                                                                            |
| GitHub Actions    | [`copilot-review-bot.yml`](../../.github/workflows/copilot-review-bot.yml) | Tests every change to `copilot-review-bot/`. On a push to `main` it builds the image and reconciles every job, through Workload Identity Federation.                                                                                                  |

### Files in this directory

| File             | Purpose                                                                                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `Dockerfile`     | The runtime image, with the bot baked in. Built from the tool directory, not from this one, because both `COPY` paths are relative to that. |
| `entrypoint.sh`  | Maps the job's environment onto the bot's flags, and passes `--args` through.                                                               |
| `jobs.json`      | Which repositories are watched, on what schedule. The source of truth.                                                                      |
| `deploy-job.sh`  | Reconciles one Cloud Run job and its tick with `jobs.json`. Idempotent.                                                                     |
| `rate-budget.sh` | Validates `jobs.json` and refuses a fleet that cannot fit the API quota.                                                                    |
| `job-config.sh`  | Derives the job name and the tick cron from an entry. Sourced by the two scripts above, so they cannot disagree.                            |

## How a change reaches production

A merge to `main` is the whole deployment path. The `test` job runs on every event, and `ship` and
`deploy` run only on a push to `main`, only after `test` passes.

```mermaid
flowchart LR
    M[Merge to main] --> T[test<br/>five suites, jobs.json schema,<br/>rate budget, image smoke test]
    T --> S[ship<br/>build, push,<br/>publish the digest]
    S --> D[deploy<br/>one leg per jobs.json entry]
    D --> J1[Cloud Run job<br/>+ tick]
    D --> J2[...one per<br/>watched repository]
```

**The image is the whole deployment.** The bot is baked into it, so what CI built is what runs.
Nothing is fetched at run time, so the job cannot execute code that did not go through CI, an
execution starts with no network round trip of its own, and the runtime needs no read access to this
repository at all, only to the watched repositories.

`docker build` is uncached, and the jobs are pinned to the image **digest**, never to a tag, so the
deployed image cannot change under them. CI asserts the match: the `test` job compares `sha256sum`
of `/app/copilot-review-bot.sh` inside the image against the working tree, and refuses to ship if
they differ.

That guarantee is about the **bot**, not the whole image; nothing in the Dockerfile is
version-pinned, so two builds of one commit can carry different tool versions. `ship` also pushes
`:<commit-sha>` and `:latest`. Nothing in production reads either; `:latest` exists only for the
one-time bootstrap build in [First-time provisioning](#first-time-provisioning-the-gcp-commands).

## Identities and permissions

Everything this tool needs access to, in one place: the GitHub token, the three GCP service
accounts, and how GitHub Actions reaches GCP. The commands that grant all of it are in [First-time
provisioning](#first-time-provisioning-the-gcp-commands).

```mermaid
flowchart LR
    W[GitHub OIDC token<br/>repository = XRPLF/ai-automation<br/>ref = refs/heads/main]
    W -- iam.workloadIdentityUser --> D[deployer]
    D -- artifactregistry.writer --> AR[Artifact Registry]
    D -- run.developer --> CR[Cloud Run]
    D -- cloudscheduler.admin --> CS[Cloud Scheduler]
    D -- iam.serviceAccountUser --> BR[bot-runtime]
    D -- iam.serviceAccountUser --> SI[scheduler-invoker]
    SI -- run.invoker, project level --> CR
    BR -- secretmanager.secretAccessor --> SEC[gh-token]
    BR -- storage.objectAdmin --> B[state bucket]
    SEC -- GH_TOKEN --> GT[GitHub PAT on each watched repository:<br/>Pull requests RW, Contents R, Issues RW,<br/>plus the Triage role and a Copilot seat]
```

### GitHub token

The token in `gh-token` needs access to **each watched repository only**, and never to
`XRPLF/ai-automation`, since nothing at run time reads this repository.

| Token type       | Scopes                                                                                                                                                                                                                                                                          |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Fine-grained PAT | `Pull requests: Read and write` to request reviews and post the error comments. `Contents: Read` so a commit's parents can be read, which is how a merge commit is told from real work. `Issues: Read and write` for the reactions. `Metadata: Read` is attached automatically. |
| Classic PAT      | `repo`, or `public_repo` if every watched repository is public, as well as `read:org`.                                                                                                                                                                                          |

A fine-grained PAT is deny-by-default even for public repositories, so each watched repository has to
be added to it explicitly.

`Issues: Read and write`, not `Issues: Read`, because the bot reacts to PR *conversation* comments as
well as inline review comments, and GitHub only exposes the reaction endpoint under `Issues`. Reading
those comments needs no `Issues` permission at all, so the gap shows up only when the bot tries to
react: `reaction.failed` at `ERROR`, exit 1. Because the reaction *is* the bookkeeping, a missing
scope makes the bot answer the same mention on every run until the `--mention-age` window closes.

Two more requirements are both silent failure modes if missed:

* The account behind the token needs at least the **Triage** repository role, the floor GitHub
  requires for requesting a review, since Copilot occupies the same "Reviewers" slot as a human
  collaborator. Triage is also the *ceiling* the bot needs: **Write is not required**. It was,
  briefly, while the bot ran `gh pr edit`, which sends a second no-op mutation that GitHub refuses
  without push access. See [Asking Copilot, by name](../README.md#asking-copilot-by-name).
* The account must separately hold a **Copilot license or seat** for the repository. Without one, the
  request is filed and never acted on, indistinguishable from the bot succeeding and Copilot ignoring
  it.

**The token has an expiry and nothing in this repository tracks it.** When it expires, every tick
fails at the first read with `event=repo.list_failed`, which diagnoses the token itself. Record the
expiry date and the owning account somewhere with a calendar attached, and rotate ahead of it.

### GCP service accounts

Three accounts, each scoped to what it alone needs.

| Account             | Used by                                                                       | Roles                                                                                                                                                                                              |
| ------------------- | ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bot-runtime`       | The Cloud Run job itself, at every tick                                       | `secretmanager.secretAccessor` on `gh-token`, `storage.objectAdmin` on the state bucket                                                                                                            |
| `scheduler-invoker` | Cloud Scheduler, to trigger the job                                           | `run.invoker`, at project level, because a per-job binding cannot be created before the job exists                                                                                                 |
| `deployer`          | GitHub Actions, through Workload Identity Federation, with no stored GCP keys | `artifactregistry.writer`, `run.developer`, `cloudscheduler.admin`, `iam.serviceAccountUser` on `bot-runtime` and on `scheduler-invoker`, `iam.workloadIdentityUser` scoped to this one repository |

`bot-runtime` and `scheduler-invoker` never leave GCP; their credentials are never held outside it.
`deployer` is the one account anything outside GCP can act as, which is why its trust is scoped as
tightly as [GitHub Actions](#github-actions) describes.

The bucket grant is `objectAdmin` rather than `objectCreator` because the bot deletes as well as
writes: it removes the lock on release and prunes stale markers.

### GitHub Actions

CI authenticates to GCP with Workload Identity Federation, not a stored service account key. The
`ship` and `deploy` jobs in
[`copilot-review-bot.yml`](../../.github/workflows/copilot-review-bot.yml) exchange a GitHub OIDC
token for short-lived credentials as `deployer`. Nothing GCP-shaped is ever committed to this
repository.

Two conditions bound who can reach that trust, and both have to hold:

* **The workload identity pool provider's attribute condition**, which restricts the OIDC exchange to
  `assertion.repository == 'XRPLF/ai-automation' && assertion.ref == 'refs/heads/main'`. Without it,
  the trust would extend to every GitHub Actions workflow on every tenant, since GitHub uses one OIDC
  issuer for all of GitHub. See [Verifying the OIDC trust](#verifying-the-oidc-trust).
* **A ruleset on `main`** requiring a pull request review before merge. The attribute condition only
  says "this repository, this branch"; the ruleset is what stops anyone with write access from
  putting arbitrary code into production on the next merge, given that `deploy` runs as `bot-runtime`
  with `gh-token` attached.

`ship` and `deploy` also gate on `github.event_name == 'push' && github.ref == 'refs/heads/main'` in
the workflow file itself. That `if:` is a second, narrower gate, not a replacement for the two above;
a change to the workflow file alone could widen it, which is exactly what the attribute condition and
the ruleset are there to stop.

## Add or change a watched repository

Add an entry to [`jobs.json`](jobs.json) and merge. CI creates the Cloud Run job, creates its tick,
and pins both to the new image. There is no `gcloud` step.

**A field name is its environment variable, lowercased.** `max_requests_per_run` sets
`MAX_REQUESTS_PER_RUN`, `lock_ttl_minutes` sets `LOCK_TTL_MINUTES`, and so on for every field that
reaches the bot that way, so the field tells you which variable to look up in [the bot's
options](../README.md#options). The exceptions are the fields that configure the platform rather
than the bot (`ticks_per_hour`, `offset_minutes`, `task_timeout`, `memory`), which become `gcloud`
flags or a derived value instead.

```json
{
  "repo": "owner/name",
  "ticks_per_hour": 4,
  "expected_open_prs": 60,
  "max_requests_per_run": 10
}
```

Neither the job name nor the cron is a field; both are derived by [`job-config.sh`](job-config.sh),
which `rate-budget.sh` and `deploy-job.sh` both source so that the fleet the budget check charges for
is the fleet that gets deployed.

| Field                        | Required | Meaning                                                                                                                                                                                                        |
| ---------------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `repo`                       | yes      | The single repository this job watches, as `owner/name`. **Must be unique**, and everything else here is derived from it.                                                                                      |
| `ticks_per_hour`             | yes      | How often the tick fires. Must divide 60 evenly: 1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30 or 60. This is the number the budget is charged on.                                                                      |
| `offset_minutes`             | no       | Minutes past the hour for the first tick, 0 to 59. Defaults to a value derived from `repo`, which staggers the fleet.                                                                                          |
| `name`                       | no       | Cloud Run job name, and its tick is this plus `-tick`. Derived from `repo` unless given. Set it only when the derived name will not do. See below.                                                             |
| `expected_open_prs`          | yes      | How many open PRs to charge the quota at. **Every** open PR, not just the ones a review could be requested on. Not a measurement and not a cap. Err high. See [When the count drifts](#when-the-count-drifts). |
| `max_requests_per_run`       | yes      | Review requests per run. Required, so it cannot differ from what the budget check charges for.                                                                                                                 |
| `max_mention_writes_per_run` | no       | Reactions and error comments per run. Default 50.                                                                                                                                                              |
| `dry_run`                    | no       | Default `false`. Must be `true` or `false`. Anything else is refused.                                                                                                                                          |
| `verbose`                    | no       | Default `true`. Must be `true` or `false`.                                                                                                                                                                     |
| `task_timeout`               | no       | Default `20m`.                                                                                                                                                                                                 |
| `lock_ttl_minutes`           | no       | Default 25.                                                                                                                                                                                                    |
| `run_deadline_seconds`       | no       | Default 900.                                                                                                                                                                                                   |
| `memory`                     | no       | Default `512Mi`.                                                                                                                                                                                               |

[`rate-budget.sh`](rate-budget.sh) validates all of this before anything is built, and asserts one
relationship that matters:

**`run_deadline_seconds` < `task_timeout` < `lock_ttl_minutes`**

The bot has to stop on its own terms before the platform kills it, and the lock has to outlive a
killed task only briefly. A task killed by its timeout runs no trap, so it releases nothing, and the
lock then blocks the schedule until its TTL expires.

### The job name is derived, not declared

`copilot-review-bot-<owner>-<name>`, lowercased. Nothing states it in `jobs.json`, which is what
stops it disagreeing with the repository it watches. The owner is in the name because it is the only
thing that keeps two organizations apart.

Cloud Run takes only lowercase letters, digits and hyphens, so `.` and `_` fold to `-`, and that
folding is not reversible: `a-b/c` and `a/b-c` both give `a-b-c`. `rate-budget.sh` therefore checks
uniqueness on the *derived* name, and refuses a fleet where two entries collide.

Set `name` explicitly for the two cases the derivation cannot serve: a collision like that, or an
owner and repository long enough to exceed the Cloud Run name limit. An explicit name still has to
carry the `copilot-review-bot` prefix, since every alert filter is a prefix match on it.

**Changing `repo` does not rename anything in GCP.** `deploy-job.sh` reconciles by job name, so a new
one creates a new job and a new tick and leaves the old pair untouched, still ticking on whatever
image it last had. Because the state path comes from the `repo` field rather than the `name` field,
the two also contend for one lock object. Delete the old pair by hand, immediately after the merge:

```bash
gcloud scheduler jobs delete <old-name>-tick --location us-central1 \
    --project xrplf-automation
gcloud run jobs delete <old-name> --region us-central1 --project xrplf-automation
```

### The ticks stagger themselves

`ticks_per_hour` says how often, and `offset_minutes` says where in the hour the first one falls; the
cron is built from the two. Leave `offset_minutes` out and it is derived from `repo`, spreading the
fleet without anybody choosing minutes by hand, and keyed on the repository rather than on position
in `jobs.json` so inserting or removing an entry never moves anybody else's tick.

That is a convenience, not a safety measure: simultaneous ticks are not a hazard worth engineering
against, since GitHub's primary quota is points per hour regardless of when they are spent, its
secondary limits are already paced by `SLEEP_BETWEEN_MUTATIONS`, and a run takes minutes, so two jobs
overlap for most of their duration whatever their offsets. Randomness would be worse: Cloud Scheduler
has no jitter, so it would have to be a sleep inside the run, eating into `run_deadline_seconds` and
making the hourly tick count non-deterministic, which is the number the whole budget check rests on.

### Removing an entry does not remove the job

`deploy-job.sh` only creates and updates, and nothing in CI deletes, so a Cloud Run job whose
`jobs.json` entry is gone keeps its tick and keeps running on whatever image it last had, forever,
with nothing in this repository pointing at it anymore. Delete both halves by hand, then list what is
deployed and compare against `jobs.json`:

```bash
gcloud scheduler jobs delete <name>-tick --location us-central1 --project xrplf-automation
gcloud run jobs delete <name> --region us-central1 --project xrplf-automation
gcloud run jobs list --region us-central1 --project xrplf-automation --filter 'metadata.name ~ ^copilot-review-bot'
```

**Never point two jobs at one repository.** The bot derives its state path from the repository it
watches, so two jobs on one repository share the lock object, and one sits out its tick waiting for
the other, indistinguishable at run time from a slow predecessor. `rate-budget.sh` refuses a
duplicate `repo` at build time for that reason, and refuses a duplicate `name`, or a name without the
`copilot-review-bot` prefix, since alert filters are prefix matches on the job name.

**Watch the first run.** The alert policies group by job name, so a new job is covered as soon as it
logs anything. Until its first `run.done` there is no time series to be absent, so that first tick is
the one window nothing is watching; confirm it, then the job is covered for good. See [Monitoring and
alerting](#monitoring-and-alerting).

## Rate limit budget

GitHub's GraphQL quota is **5000 points per hour, per token**. Every job uses the same `gh-token`, so
adding a repository spends the other jobs' budget.

When the quota runs out, reads start failing part way through a run: each is an ERROR
`pr.read_failed`, and after three in a row the run stops with `reason=read_failures` and leaves the
rest for the next run. So the failure is reported rather than silent, but the repository still goes
uninspected.

The arithmetic is therefore a build step. `rate-budget.sh` sums the hourly cost of every entry in
`jobs.json`, fails the build above the quota, and warns from 80%. It runs in `test`, before the image
is built, so the pull request that would break the budget cannot merge.

Per-call costs are measured against a real repository with `rateLimit { cost }` on the bot's own
queries, since cost is not derivable from the node count:

| Call                                       | Cost              |
| ------------------------------------------ | ----------------- |
| `Q_REPO_PRS`, 100 PR numbers               | 1 point           |
| `Q_PR`, one PR in full                     | 2 points          |
| `{ viewer { login } }`, once per run       | 1 point           |
| A review request (`requestReviewsByLogin`) | 3 points, charged |
| A reaction or error comment                | 1 point           |

The review request figure is charged higher than measured, deliberately, as unmeasured headroom
rather than a number to trim.

The model is a deliberate upper bound: it charges the full request cap **and** the full mention cap
**and** every PR read in one run, which cannot all happen together, since the sweep stops as soon as
the request cap is reached. Actual spend in an idle hour runs well below the charged figure.

**Lowering `ticks_per_hour` is the lever, not raising a cap.** Halving it halves a job's hourly cost.
Lowering `max_requests_per_run` barely helps, since almost all the cost is reads. Past that, the only
real headroom is a second token.

### When the count drifts

**Count every open PR, not the ones that look eligible.** The list query asks for `states: OPEN` and
nothing else, so a draft or a PR targeting another branch is still fetched in full and *then*
skipped, at the same 2 points as one the bot acts on. The count the bot logs as `open_prs` on
`repo.start` is already unfiltered, which is why that is the figure to charge for.

`expected_open_prs` is a declared figure, not a measurement, and **it constrains nothing at run
time**: the bot reads however many open PRs there are. It decides two things only: whether CI lets
you merge, and whether a run tells you it has gone stale. So a repository that grows does not quietly
cost more than it should; it costs what it costs, and three things happen in order:

1. The bot logs `repo.more_prs_than_expected` at WARNING on every run, naming both numbers and the
   gap. Your ERROR/WARNING alerting already catches this.
2. Nothing else changes, until real spend approaches the quota.
3. Past the quota, reads start failing part way through a run, then the sweep halts with
   `reason=read_failures` and a non-zero exit. Loud, and the remaining PRs are left to the next run
   rather than dropped.

**Err high, but not wildly.** The two directions are not symmetric: declaring too high refuses a
fleet that would have fitted, which is immediate and visible and costs nothing but a re-check.
Declaring too low permits a fleet that does not fit, which costs coverage, and the symptom lands on
whichever job reads last rather than on the one that was mis-declared. So round up, comfortably past
the observed peak, and re-check when adding a job. Compare against what every run logs:

```bash
gcloud logging read 'jsonPayload.event="repo.start"' --project xrplf-automation \
    --limit 10 --format 'value(jsonPayload.repo, jsonPayload.open_prs)'
```

The real hazard is not the drift itself, which is loud on both ends. It is **adding a third job on
the strength of a stale total**, since that decision is made from `rate-budget.sh` output, which is
only as good as the declared figures behind it.

## Configuration

`jobs.json` is the source of truth for everything per job. `deploy-job.sh` uses `--set-env-vars`,
which **replaces** the whole set, so a variable changed by hand is corrected on the next merge, and
one dropped from `jobs.json` returns to its default. That is deliberate: an environment variable
nobody can find in the repository is how a job ends up running in a mode nobody chose. To change a
setting, change `jobs.json`. A `gcloud` edit lasts until the next push to `main`.

Inspect what a job actually has with:

```bash
gcloud run jobs describe <job> --region us-central1 --project xrplf-automation
```

### Three job settings are fixed, not configurable

`deploy-job.sh` states these on every job rather than exposing them through `jobs.json`, because the
right value is a property of how the bot works rather than of a repository.

| Setting         | Value | Why                                                                                                                                                                                               |
| --------------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--max-retries` | `0`   | **A failed execution is never retried.** The next tick is the retry, and it re-reads everything from GitHub, so an immediate retry would only repeat whatever just failed against the same state. |
| `--tasks`       | `1`   | Two tasks would contend for one lock object; one would take it, the other would log `run.skipped` and exit 0, so half the work of every tick would silently not happen.                           |
| `--parallelism` | `1`   | The same reason, stated on the axis Cloud Run scales.                                                                                                                                             |

`--max-retries 0` is the one to remember on call: a red execution in the console stays red, and
what matters is whether the *next* tick succeeded, which is what the absence alert on `run.done`
measures.

### State lives in a bucket, not in `/tmp`

`STATE_DIR` must be a `gs://` URL, and `deploy-job.sh` sets it to the bucket root, `gs://<bucket>`,
with no prefix. A Cloud Run execution gets a fresh filesystem, so a local path would lose the
head-commit marker per PR, which is what stops a second review request in the window before GitHub
reports the first one as pending.

The bot namespaces the root itself, by the repository it watches, so every job writes to its own
place without declaring where that is:

```text
gs://xrplf-copilot-review-bot-state/<owner>/<name>/lock
gs://xrplf-copilot-review-bot-state/<owner>/<name>/requested.json
```

The state is not a source of truth, so losing the bucket is survivable rather than fatal, which is
why a local `STATE_DIR` warns (`event=state.ephemeral`) rather than refusing to run. It warns on
every run until fixed.

The bucket needs no credentials of its own: the bot asks the instance metadata server for a
short-lived token for the job's service account, so the IAM granted to `bot-runtime` is what applies.

**Keep `lock_ttl_minutes` just above `task_timeout`.** Below it, a slow but healthy run gets its lock
stolen. Far above it, a killed run blocks every tick until the window expires. How the lock itself
works is in [the bot's README](../README.md#state-and-locking).

## Runbook

Cloud Run marks an execution failed when a task exits non-zero, and the bot's exit codes are right
for that: 1 for a permanent per-PR error, 2 for fatal. Nothing forwards that anywhere, so the alerts
in the next section have to exist or a broken bot is silent.

### Symptoms

Every event named here is defined in [What it logs](../README.md#what-it-logs), and every
`run.fatal` reason in [the table beside it](../README.md#why-a-run-could-not-start-runfatal). The
two `entrypoint.*` events below come from `entrypoint.sh` rather than the bot.

| Symptom                                         | Likely cause                                                                                                             | What to do                                                                                                                                               |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No `run.done` for three ticks                   | A lock left behind by a killed run, or a paused tick. Both exit 0, so neither shows as a failed execution.               | Count `run.skipped`. Then check the tick with `gcloud scheduler jobs describe`.                                                                          |
| `run.skipped` with `reason=locked`, repeatedly  | A previous run still holds the lock.                                                                                     | For a `gs://` state root the lock is broken automatically after `LOCK_TTL_MINUTES`. Wait one TTL. If it recurs, the runs are overrunning their schedule. |
| `repo.list_failed` or `repo.read_failed`        | The token expired, or it cannot see the repository. The `access.*` events carry the diagnosis and a `remedy` code.       | Run the three checks below.                                                                                                                              |
| `run.fatal` with `reason=state_bucket_unusable` | `bot-runtime` cannot write to the bucket.                                                                                | 403 is a missing `roles/storage.objectAdmin`. 404 is a bucket that does not exist.                                                                       |
| `run.fatal` with `reason=no_credentials`        | The `gh-token` secret is not attached, or its latest version is empty.                                                   | Check `--set-secrets GH_TOKEN=gh-token:latest` on the job, then add a new secret version.                                                                |
| `reaction.failed` at `ERROR`                    | The token lacks `Issues: Read and write`.                                                                                | Grant it. See [GitHub token](#github-token). Until then the same mention is answered on every run.                                                       |
| `requests.halted` at `ERROR`                    | Two permanent failures in a row, which is almost always repository-wide.                                                 | Check that the account still holds the Triage role and a Copilot seat, and that the `reviewer` on the event still resolves.                              |
| `repo.more_prs_than_expected`                   | The repository has outgrown its `expected_open_prs`, so the fleet is spending more than it was sized for.                | Raise the figure in `jobs.json` and re-run the budget check. See [When the count drifts](#when-the-count-drifts).                                        |
| `state.ephemeral`                               | `STATE_DIR` is a local path, so markers are lost between executions.                                                     | Set it to the bucket root through `jobs.json`.                                                                                                           |
| Requests are filed but no review appears        | Copilot is rate-limited or has no seat. The bot cannot tell that from a slow review.                                     | Check the PR by hand. The bot will not re-request while the request stays pending.                                                                       |
| `entrypoint.bot_missing`                        | The image carries no executable bot at `/app/copilot-review-bot.sh`, so no run happened at all.                          | Nothing in the job can fix this. Roll back to an older digest, then work out how it passed the CI smoke test, which checks exactly this.                 |
| `entrypoint.bad_setting`                        | `DRY_RUN` or `VERBOSE` is set to something other than `true` or `false`. Almost always a job environment edited by hand. | Correct it in `jobs.json` and merge.                                                                                                                     |
| One execution is red and nothing retried it     | Expected. The job sets `--max-retries 0`.                                                                                | Check whether the next tick succeeded. See [the fixed job settings](#three-job-settings-are-fixed-not-configurable).                                     |

A token that authenticates is not the same as a token that can see the repository. Fine-grained PATs
are deny-by-default and can only reach repositories explicitly granted to them, **public
repositories included**, so a valid fine-grained PAT can fail on a public repository an anonymous
client reads without trouble. Check by hand:

```bash
gh api user --jq .login                      # is the token valid at all?
gh api repos/<owner>/<name> --jq .full_name  # can it see the repository?
curl -sS -o /dev/null -w '%{http_code}\n' https://api.github.com/repos/<owner>/<name>
                                             # what an anonymous client sees
```

If the first two disagree, it is the token's resource scoping and not the repository. Filing requests
also needs `Pull requests: Read and write` and at least the Triage role.

### Day-to-day commands

```bash
# Run once, now:
gcloud run jobs execute <job> --region us-central1 --project xrplf-automation

# Run once against a single PR, without changing the job. The entrypoint passes
# arguments through, and --pr / --base / --explain have no env equivalent.
gcloud run jobs execute <job> --region us-central1 \
    --project xrplf-automation --args=--dry-run,--verbose,--pr,<number>

# Logs from the latest executions. The bot emits one JSON object per line, so
# severity, message and time are promoted onto the entry and everything else is
# in jsonPayload.
gcloud logging read 'resource.type=cloud_run_job
    resource.labels.job_name=<job>' \
    --project xrplf-automation --limit 200 \
    --format 'value(severity, jsonPayload.event, jsonPayload.message)'

# Just the problems, across every job:
gcloud logging read 'resource.type=cloud_run_job
    resource.labels.job_name:copilot-review-bot AND severity>=WARNING' \
    --project xrplf-automation --limit 50 --format 'value(jsonPayload)'

# One PR's history, using the promoted labels:
gcloud logging read 'resource.type=cloud_run_job
    labels.repo="<owner>/<name>" AND labels.pr="<number>"' \
    --project xrplf-automation --limit 50 --format 'value(jsonPayload)'

# What a job's state currently holds. The path is the bucket root plus the repository.
gcloud storage cat gs://xrplf-copilot-review-bot-state/<owner>/<name>/requested.json \
    --project xrplf-automation | jq .

# Pause / resume one tick:
gcloud scheduler jobs pause  <job>-tick --location us-central1 --project xrplf-automation
gcloud scheduler jobs resume <job>-tick --location us-central1 --project xrplf-automation
```

### Rotate the token

```bash
printf '%s' "$NEW_TOKEN" | gcloud secrets versions add gh-token --data-file=- --project xrplf-automation
```

The job reads `gh-token:latest`, so the next tick picks the new version up. No deployment is needed.

### Stop or roll back

Pointing a job at an older image is one command and needs no build:

```bash
gcloud run jobs update <job> --region us-central1 --project xrplf-automation \
    --image us-central1-docker.pkg.dev/xrplf-automation/images/copilot-review-bot:<older-sha>
```

**The next push to `main` undoes this.** The `deploy` job re-pins every job to the newest image by
design, so this is an emergency stop, not a fix. To keep an old version running, revert the commit on
`main` and let CI ship the revert.

If you need longer than one merge cycle, pause the tick instead:

```bash
gcloud scheduler jobs pause <job>-tick --location us-central1 --project xrplf-automation
```

A paused tick is the one failure mode that produces no error at all. The absence alert below is what
catches it being left that way.

## Monitoring and alerting

The important alert is the **absence** alert, because the worst failure modes exit 0 and never show
up as a failed execution: a lock left behind by a killed run makes every tick a green no-op, and a
paused tick does nothing at all. What they have in common is that no `run.done` appears, which is the
only thing that catches them.

**Nothing here is per job, and it is worth knowing why.** The metric filters use a prefix match on
`job_name:copilot-review-bot`, so a new job is covered the moment it logs anything, and the policies
**group by `resource.label."job_name"`**, so each job is judged on its own and a new one is picked up
without a policy edit. Summing across jobs would be the mistake, since a total cannot tell "all
healthy" from "one dead, one busy". Grouping is not summing.

One gap survives that: an absence condition cannot fire for a time series that has never existed, so
a job broken from its very first tick has nothing to be absent. That window runs from the merge to
the first successful run, which is when somebody is watching anyway; after that the job is covered
for good. The error policy has no such gap, since any job's ERROR increments it.

```bash
# Dead man's switch: no successful completion in 45 minutes (three missed ticks).
gcloud logging metrics create copilot_review_bot_done --project xrplf-automation \
    --description "One per completed copilot-review-bot run" \
    --log-filter 'resource.type=cloud_run_job
        resource.labels.job_name:copilot-review-bot
        jsonPayload.event="run.done"'

# Anything the bot itself calls an error.
gcloud logging metrics create copilot_review_bot_errors --project xrplf-automation \
    --description "ERROR-severity events from copilot-review-bot" \
    --log-filter 'resource.type=cloud_run_job
        resource.labels.job_name:copilot-review-bot AND severity>=ERROR'

# Review requests actually filed, so "reviews stopped happening" is a number.
gcloud logging metrics create copilot_review_bot_requests --project xrplf-automation \
    --description "Review requests filed per run" \
    --log-filter 'resource.type=cloud_run_job
        resource.labels.job_name:copilot-review-bot
        jsonPayload.event="run.done"' \
    --value-extractor 'EXTRACT(jsonPayload.requests_filed)'

# Runs that found the lock held. Repeatedly is a wedged lock, which is one of the
# two failure modes that exit 0 and so never show as a failed execution.
gcloud logging metrics create copilot_review_bot_skipped --project xrplf-automation \
    --description "Runs that found the lock held" \
    --log-filter 'resource.type=cloud_run_job
        resource.labels.job_name:copilot-review-bot
        jsonPayload.event="run.skipped"'
```

Then create alert policies on those metrics:

| Metric                        | Policy                                             | Group by                    |
| ----------------------------- | -------------------------------------------------- | --------------------------- |
| `copilot_review_bot_done`     | Absent for 45 minutes, which is three missed ticks | `resource.label."job_name"` |
| `copilot_review_bot_errors`   | Above 0                                            | `resource.label."job_name"` |
| `copilot_review_bot_skipped`  | More than twice in an hour, which is a wedged lock | `resource.label."job_name"` |
| `copilot_review_bot_requests` | No policy, on purpose                              | -                           |

`copilot_review_bot_requests` has none because it is for the dashboard: "reviews stopped happening"
is a number to look at rather than an alert that fires on a quiet afternoon.

Create the notification channel first, and keep the name it returns, because the policies reference
it. A policy with no notification channel is inert:

```bash
gcloud beta monitoring channels create --project xrplf-automation \
    --display-name "copilot-review-bot oncall" \
    --type email --channel-labels email_address=ONCALL@EXAMPLE.COM
gcloud beta monitoring channels list --project xrplf-automation \
    --format 'value(name,displayName)'
```

Then the policies:

```bash
gcloud monitoring policies create --project xrplf-automation --policy-from-file=absence.json
```

The absence policy is the one that matters, and `groupByFields` is the load-bearing line: it is what
makes one policy cover the fleet rather than one job.

```json
{
  "displayName": "copilot-review-bot: no run.done in 45 minutes",
  "combiner": "OR",
  "conditions": [{
    "displayName": "run.done absent for 45m, per job",
    "conditionAbsent": {
      "filter": "metric.type=\"logging.googleapis.com/user/copilot_review_bot_done\" AND resource.type=\"cloud_run_job\"",
      "aggregations": [{
        "alignmentPeriod": "300s",
        "perSeriesAligner": "ALIGN_SUM",
        "crossSeriesReducer": "REDUCE_SUM",
        "groupByFields": ["resource.label.\"job_name\""]
      }],
      "duration": "2700s",
      "trigger": { "count": 1 }
    }
  }],
  "notificationChannels": ["projects/xrplf-automation/notificationChannels/CHANNEL_ID"],
  "alertStrategy": { "autoClose": "604800s" }
}
```

The other two are the same file with `conditionThreshold` in place of `conditionAbsent`, the same
`groupByFields`, and these values:

| Policy       | Metric                       | Comparison                           | `alignmentPeriod` | `duration` |
| ------------ | ---------------------------- | ------------------------------------ | ----------------- | ---------- |
| ERROR events | `copilot_review_bot_errors`  | `COMPARISON_GT`, `thresholdValue: 0` | `300s`            | `0s`       |
| Wedged lock  | `copilot_review_bot_skipped` | `COMPARISON_GT`, `thresholdValue: 2` | `3600s`           | `0s`       |

**The aligner is required, not decoration.** A log-based counter is a DELTA metric, so without
`perSeriesAligner` the absence condition would read a gap between data points as "no runs" rather
than waiting the full duration.

Confirm the grouping landed, because a policy that silently lost it looks identical until the day a
second job dies quietly:

```bash
gcloud monitoring policies list --project xrplf-automation \
    --format 'value(displayName, conditions[0].conditionAbsent.aggregations[0].groupByFields)'
```

**These are created by hand, not by CI.** Automating it would need `deployer` to hold
`roles/monitoring.editor` on top of the project-level Cloud Run role it already has, and the policy
create command is not idempotent, so it would need the same reconcile logic as `deploy-job.sh` for
comparatively little gain, since grouping by job name is what already keeps new jobs covered without
a policy edit.

## Set it up from scratch

Eight steps, in order. Everything here already exists for the repositories in
[`jobs.json`](jobs.json), so the whole list is the path for a **new organization or a new GCP
project**. Adding a repository to the existing setup is steps 3, 7 and 8 only, plus step 4 if the
token is a fine-grained PAT, since that kind has to be granted each repository explicitly.

The two halves are independent until step 5: the GitHub half decides what the bot may do, and the GCP
half decides what may run it. Two of the eight steps are not automated at all.

```mermaid
%%{init: {'flowchart': {'nodeSpacing': 18, 'rankSpacing': 34}, 'themeVariables': {'fontSize': '13px'}}}%%
flowchart LR
    subgraph gh[On GitHub]
        G1[1 Bot account] --> G2[2 Copilot seat<br/>on that account]
        G2 --> G3[3 Triage role on each<br/>watched repository]
        G3 --> G4[4 PAT: Pull requests RW,<br/>Contents R, Issues RW]
        G6[6 Ruleset on main:<br/>review before merge]
    end
    subgraph gcp[In the GCP project]
        C1[5 APIs, bucket,<br/>three service accounts,<br/>identity pool, secret]
    end
    G4 -- becomes a secret version --> C1
    C1 --> M[7 Merge a jobs.json entry.<br/>CI creates the job<br/>and its tick.]
    G6 --> M
    M --> AL[8 By hand, once:<br/>the alert policies,<br/>grouped by job name]
```

| Step | Do                                                                                          | Automated | Detail                                                                    |
| ---- | ------------------------------------------------------------------------------------------- | --------- | ------------------------------------------------------------------------- |
| 1    | Create the bot account, such as `@xrplf-bot`. One account serves every watched repository.  | no        | [Why the bot exists](../README.md#why-the-bot-exists)                     |
| 2    | Give that account a Copilot license or seat. Without one, requests are filed and ignored.   | no        | [GitHub token](#github-token)                                             |
| 3    | Grant the account at least the **Triage** role on each watched repository.                  | no        | [GitHub token](#github-token)                                             |
| 4    | Mint a PAT on that account: `Pull requests` RW, `Contents` R, `Issues` RW.                  | no        | [GitHub token](#github-token)                                             |
| 5    | Provision the GCP project, and add the PAT as a `gh-token` version.                         | scripted  | [The GCP commands](#first-time-provisioning-the-gcp-commands)             |
| 6    | Create the ruleset on `main` requiring a review before merge.                               | no        | [GitHub Actions](#github-actions)                                         |
| 7    | Add a `jobs.json` entry and merge. CI creates the Cloud Run job and its tick.               | yes       | [Add or change a watched repository](#add-or-change-a-watched-repository) |
| 8    | Create the log metrics and alert policies, once. Grouped by job name, they cover every job. | no        | [Monitoring and alerting](#monitoring-and-alerting)                       |

Steps 2 and 3 are the two that fail silently if missed: a missing Copilot seat means every request
succeeds and no review ever arrives, and a missing Triage role means every request is refused.
Neither is visible from the bot's own configuration, so confirm both before blaming anything else.

Step 6 is not optional. The workload identity pool's attribute condition says "this repository, this
branch", not "only through review"; the ruleset is the other half.

## First-time provisioning: the GCP commands

This is step 5 above, already applied in `xrplf-automation`. Recorded here so the setup is
reproducible.

```bash
PROJECT=xrplf-automation
REGION=us-central1
BUCKET=xrplf-copilot-review-bot-state
gcloud services enable run.googleapis.com cloudscheduler.googleapis.com \
    secretmanager.googleapis.com artifactregistry.googleapis.com \
    storage.googleapis.com cloudbuild.googleapis.com \
    iamcredentials.googleapis.com sts.googleapis.com --project $PROJECT

# State bucket. Private, uniform access, one region. Nothing in it is a secret,
# but nothing in it should be public either.
gcloud storage buckets create gs://$BUCKET --project $PROJECT \
    --location $REGION --uniform-bucket-level-access \
    --public-access-prevention

# Image repo. Later builds come from the GitHub workflow. This first one exists
# only so the repository is not empty.
#
# Run from the repository root. The source uploaded is copilot-review-bot/, which is
# the build context the Dockerfile's COPY paths are relative to, so the step below
# builds from `.` within it.
gcloud artifacts repositories create images --repository-format=docker \
    --location $REGION --project $PROJECT
gcloud builds submit copilot-review-bot --project $PROJECT --config - <<'EOF'
steps:
  - name: gcr.io/cloud-builders/docker
    args: [build, -f, deploy/Dockerfile, -t, "$_IMAGE", .]
images: ["$_IMAGE"]
substitutions:
  _IMAGE: us-central1-docker.pkg.dev/xrplf-automation/images/copilot-review-bot:latest
EOF

# Secret (add the real PAT as a version).
gcloud secrets create gh-token --replication-policy automatic --project $PROJECT

# Runtime service account, minimal: read the token, read and write its own
# bucket. objectAdmin rather than objectCreator, because the lock is deleted on
# release and stale markers are pruned.
gcloud iam service-accounts create bot-runtime --project $PROJECT
gcloud secrets add-iam-policy-binding gh-token --project $PROJECT \
    --member serviceAccount:bot-runtime@$PROJECT.iam.gserviceaccount.com \
    --role roles/secretmanager.secretAccessor
gcloud storage buckets add-iam-policy-binding gs://$BUCKET --project $PROJECT \
    --member serviceAccount:bot-runtime@$PROJECT.iam.gserviceaccount.com \
    --role roles/storage.objectAdmin

# Scheduler invoker, granted at *project* level rather than per job. A per-job
# binding cannot be created before the job exists, so CI would need
# run.jobs.setIamPolicy to add one - which means roles/run.admin for the deployer
# instead of roles/run.developer. One project-level binding on an account that can
# do nothing but invoke is the narrower of the two.
gcloud iam service-accounts create scheduler-invoker --project $PROJECT
gcloud projects add-iam-policy-binding $PROJECT \
    --member serviceAccount:scheduler-invoker@$PROJECT.iam.gserviceaccount.com \
    --role roles/run.invoker

# CI/CD identity for GitHub Actions (Workload Identity Federation).
#
# GitHub uses one issuer URL for every tenant, so the issuer identifies all of
# GitHub rather than this organization. The attribute condition below is therefore
# the only thing that makes the trust specific, and it is load-bearing twice: it is
# both the tenant gate and the ref gate, because the workloadIdentityUser binding
# further down matches the whole repository. Relax it and that binding silently
# widens to every branch.
gcloud iam workload-identity-pools create github --location global --project $PROJECT
# Defense in depth. The ship job already gates on the event and the ref, so this
# condition is what stops a change to the workflow alone widening who can deploy -
# and the deployer can run the job as bot-runtime with the gh-token secret
# attached, so it is worth checking in two places.
gcloud iam workload-identity-pools providers create-oidc github-oidc \
    --location global --workload-identity-pool github --project $PROJECT \
    --issuer-uri https://token.actions.githubusercontent.com \
    --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition "assertion.repository == 'XRPLF/ai-automation' && assertion.ref == 'refs/heads/main'"
gcloud iam service-accounts create deployer --project $PROJECT
gcloud projects add-iam-policy-binding $PROJECT \
    --member serviceAccount:deployer@$PROJECT.iam.gserviceaccount.com \
    --role roles/artifactregistry.writer
# Project level, not per job, because CI creates jobs as well as updating them and
# a binding cannot precede its resource. This is wider than the per-job binding it
# replaces: the deployer can now touch every Cloud Run resource in the project. The
# OIDC condition above and the `ship` job's own `if:` are what bound who reaches it.
gcloud projects add-iam-policy-binding $PROJECT \
    --member serviceAccount:deployer@$PROJECT.iam.gserviceaccount.com \
    --role roles/run.developer
gcloud projects add-iam-policy-binding $PROJECT \
    --member serviceAccount:deployer@$PROJECT.iam.gserviceaccount.com \
    --role roles/cloudscheduler.admin
# Attaching a service account to a resource needs actAs on *that* account, so the
# deployer needs one binding per account it attaches: bot-runtime for the Cloud Run
# job, and scheduler-invoker for the tick. Without the second one, a project rebuilt
# from this block creates the job and then fails on `scheduler jobs create http`.
gcloud iam service-accounts add-iam-policy-binding \
    bot-runtime@$PROJECT.iam.gserviceaccount.com --project $PROJECT \
    --member serviceAccount:deployer@$PROJECT.iam.gserviceaccount.com \
    --role roles/iam.serviceAccountUser
gcloud iam service-accounts add-iam-policy-binding \
    scheduler-invoker@$PROJECT.iam.gserviceaccount.com --project $PROJECT \
    --member serviceAccount:deployer@$PROJECT.iam.gserviceaccount.com \
    --role roles/iam.serviceAccountUser
PROJECT_NUMBER=$(gcloud projects describe $PROJECT --format 'value(projectNumber)')
gcloud iam service-accounts add-iam-policy-binding \
    deployer@$PROJECT.iam.gserviceaccount.com --project $PROJECT \
    --member "principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/attribute.repository/XRPLF/ai-automation" \
    --role roles/iam.workloadIdentityUser
```

The first Cloud Run job and its tick are **not** created here. Merging a `jobs.json` entry does that.

### Verifying the OIDC trust

The block above records the *intended* trust. Nothing in this repository can confirm the live
provider still matches it, and that condition is the one control between "our workflow" and "any
workflow on GitHub". Check it, and record the output:

```bash
gcloud iam workload-identity-pools providers describe github-oidc \
    --location global --workload-identity-pool github --project xrplf-automation \
    --format 'value(attributeCondition)'
# Expected: assertion.repository == 'XRPLF/ai-automation' && assertion.ref == 'refs/heads/main'
```

An empty result means the provider trusts every GitHub tenant, and the only remaining gate is the
`ship` job's own `if:`, which lives in a file that anyone with write access can edit.

**The `sub` claim does not have the shape the GitHub documentation shows**; on this project it
carries numeric ids rather than the documented `repo:OWNER/NAME:ref:...` form. Nothing here depends
on it, since the condition and the binding both use the separate `assertion.repository` and
`assertion.ref` claims. Do not rewrite either one to bind `principal://` on `google.subject` using the
documented pattern: it would not match, and the failure looks like a permissions problem rather than
a format mismatch.

## Related documents

* [../README.md](../README.md) - what the bot decides, its options, and what it logs.
* [../tests/README.md](../tests/README.md) - the suites, and how to run the bot by hand.
* [../../README.md](../../README.md) - the repository, and the CI that ships this.
</content>

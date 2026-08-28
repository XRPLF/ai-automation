# Deployment — GCP `xrplf-automation`

The copilot-review-bot runs as a **Cloud Run Job** in the `xrplf-automation`
project, triggered by **Cloud Scheduler** every 15 minutes. There is no VM, no
inbound endpoint, and nothing running between ticks.

## How the pieces fit

| Piece | Name | Purpose |
| --- | --- | --- |
| Cloud Run Job | `copilot-review-bot` | One bot run per execution (`us-central1`). |
| Cloud Scheduler | `copilot-review-bot-tick` | Executes the job every 15 minutes. |
| Secret Manager | `gh-token` | The bot account's GitHub PAT, injected as `GH_TOKEN`. |
| Artifact Registry | `images/copilot-review-bot` | Runtime image (Debian + bash 5 + gh + jq). |
| GitHub Actions | `.github/workflows/deploy.yml` | Rebuilds the image and updates the job when `deploy/**` changes, via Workload Identity Federation (no stored GCP keys). |

**Bot code is never baked into the image.** The entrypoint clones the latest
`main` of this repo at the start of every execution, so merging a change to
`copilot-review-bot/` is live on the next 15-minute tick. Only changes under
`deploy/` need an image rebuild, and the workflow does that on merge.

State (`STATE_DIR`) is ephemeral (`/tmp`) on purpose: the bot re-derives every
decision from GitHub, reactions are the mention bookkeeping, and the README of
the bot documents that losing state is safe. `COPILOT_BOT_ID` is pinned in the
job's environment so no discovery scan is needed on a cold start.

## Configuration knobs

Set on the job (visible with `gcloud run jobs describe copilot-review-bot`):

* `REPOS` — repos to watch, e.g. `"XRPLF/rippled XRPLF/xrpld-private"`.
* `DRY_RUN` / `VERBOSE` — `"true"`/`"false"`, mapped to the bot's flags.
* `REPO_REF` — branch of this repo to run the bot from (default `main`).

Change one:

```bash
gcloud run jobs update copilot-review-bot --region us-central1 \
    --project xrplf-automation --update-env-vars DRY_RUN=false
```

## Operations

```bash
# Run once, now:
gcloud run jobs execute copilot-review-bot --region us-central1 --project xrplf-automation

# Logs from the latest executions:
gcloud logging read 'resource.type=cloud_run_job resource.labels.job_name=copilot-review-bot' \
    --project xrplf-automation --limit 200 --format 'value(textPayload)'

# Pause / resume the schedule:
gcloud scheduler jobs pause  copilot-review-bot-tick --location us-central1 --project xrplf-automation
gcloud scheduler jobs resume copilot-review-bot-tick --location us-central1 --project xrplf-automation

# Rotate the GitHub token:
printf '%s' "$NEW_TOKEN" | gcloud secrets versions add gh-token --data-file=- --project xrplf-automation
```

## One-time provisioning

Everything below already exists in `xrplf-automation`; recorded here so the
setup is reproducible.

```bash
PROJECT=xrplf-automation
REGION=us-central1
gcloud services enable run.googleapis.com cloudscheduler.googleapis.com \
    secretmanager.googleapis.com artifactregistry.googleapis.com \
    iamcredentials.googleapis.com sts.googleapis.com --project $PROJECT

# Image repo + first image (later builds come from the GitHub workflow).
gcloud artifacts repositories create images --repository-format=docker \
    --location $REGION --project $PROJECT
gcloud builds submit deploy/ --project $PROJECT \
    --tag $REGION-docker.pkg.dev/$PROJECT/images/copilot-review-bot:latest

# Secret (add the real PAT as a version).
gcloud secrets create gh-token --replication-policy automatic --project $PROJECT

# Runtime service account, minimal.
gcloud iam service-accounts create bot-runtime --project $PROJECT
gcloud secrets add-iam-policy-binding gh-token --project $PROJECT \
    --member serviceAccount:bot-runtime@$PROJECT.iam.gserviceaccount.com \
    --role roles/secretmanager.secretAccessor

# The job.
gcloud run jobs create copilot-review-bot --project $PROJECT --region $REGION \
    --image $REGION-docker.pkg.dev/$PROJECT/images/copilot-review-bot:latest \
    --service-account bot-runtime@$PROJECT.iam.gserviceaccount.com \
    --set-secrets GH_TOKEN=gh-token:latest \
    --set-env-vars "REPOS=XRPLF/rippled,DRY_RUN=true,VERBOSE=true,COPILOT_BOT_ID=BOT_kgDOC9w8XQ" \
    --max-retries 0 --task-timeout 10m --memory 512Mi

# Scheduler → job, via an invoker service account.
gcloud iam service-accounts create scheduler-invoker --project $PROJECT
gcloud run jobs add-iam-policy-binding copilot-review-bot --region $REGION --project $PROJECT \
    --member serviceAccount:scheduler-invoker@$PROJECT.iam.gserviceaccount.com \
    --role roles/run.invoker
gcloud scheduler jobs create http copilot-review-bot-tick --project $PROJECT \
    --location $REGION --schedule "*/15 * * * *" \
    --uri "https://run.googleapis.com/v2/projects/$PROJECT/locations/$REGION/jobs/copilot-review-bot:run" \
    --http-method POST \
    --oauth-service-account-email scheduler-invoker@$PROJECT.iam.gserviceaccount.com

# CI/CD identity for GitHub Actions (Workload Identity Federation).
gcloud iam workload-identity-pools create github --location global --project $PROJECT
gcloud iam workload-identity-pools providers create-oidc github-oidc \
    --location global --workload-identity-pool github --project $PROJECT \
    --issuer-uri https://token.actions.githubusercontent.com \
    --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository" \
    --attribute-condition "assertion.repository == 'XRPLF/ai-automation'"
gcloud iam service-accounts create deployer --project $PROJECT
gcloud projects add-iam-policy-binding $PROJECT \
    --member serviceAccount:deployer@$PROJECT.iam.gserviceaccount.com \
    --role roles/artifactregistry.writer
gcloud projects add-iam-policy-binding $PROJECT \
    --member serviceAccount:deployer@$PROJECT.iam.gserviceaccount.com \
    --role roles/run.developer
gcloud iam service-accounts add-iam-policy-binding \
    bot-runtime@$PROJECT.iam.gserviceaccount.com --project $PROJECT \
    --member serviceAccount:deployer@$PROJECT.iam.gserviceaccount.com \
    --role roles/iam.serviceAccountUser
PROJECT_NUMBER=$(gcloud projects describe $PROJECT --format 'value(projectNumber)')
gcloud iam service-accounts add-iam-policy-binding \
    deployer@$PROJECT.iam.gserviceaccount.com --project $PROJECT \
    --member "principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github/attribute.repository/XRPLF/ai-automation" \
    --role roles/iam.workloadIdentityUser
```

## Going live checklist

1. Add the bot account's PAT as a `gh-token` secret version (rotate command
   above).
2. Execute once and read the dry-run log (commands above).
3. Flip live: `--update-env-vars DRY_RUN=false`.
4. Widen `REPOS` to include `XRPLF/xrpld-private` once the PAT is granted
   there.

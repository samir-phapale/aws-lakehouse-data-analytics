# Deploying and running the lakehouse (dev)

The main Terraform root (`infrastructure/terraform`) is deployed only by CodePipeline. The
pipeline is bootstrapped once by hand; after that every push to `main` is planned, checked by
OPA, approved by a person and applied. The stack stays up while work continues and is destroyed
once, at the end.

All commands run from the repo root in Git Bash (PowerShell opens `.sh` files instead of running them).

```bash
aws sso login --profile vr-sso
export AWS_PROFILE=vr-sso AWS_REGION=us-east-1
```

## 1. Bootstrap the pipeline (once)

Full steps and what the pipeline root creates: [cicd/README.md](../../cicd/README.md). In short:

1. Give the project its own Git repository (the enclosing repo is the whole `VS_Code` folder) and
   push it to GitHub: `git init -b main`, commit, then
   `gh repo create samir-phapale/aws-lakehouse-data-analytics --public --source . --push`.
2. Apply the pipeline root `cicd/terraform` by hand.
3. Authorize the GitHub connection `lakehouse-dev-github` once in the console (Developer Tools ->
   Settings -> Connections -> Update pending connection).
4. Make its CodeBuild role a Lake Formation admin:
   `scripts/add_lake_formation_admin.sh "$(terraform -chdir=cicd/terraform output -raw codebuild_role_arn)"`.

## 2. Deploy through the pipeline

Start the first run with Release change on `lakehouse-dev-pipeline`; after that every push to
`main` on GitHub starts it:

```bash
git push origin main
```

Read the plan in the Plan build log (CodeBuild ->
`lakehouse-dev-validate-plan`), then approve in the console (CodePipeline ->
`lakehouse-dev-pipeline` -> Approve -> Review). A fresh deploy is 239 resources; RDS takes about
10 minutes and MSK about 25-30.

Every later change follows the same path: commit, push, approve.

Break-glass only: if the pipeline itself is broken, a laptop `terraform apply` of the main root
needs the user's explicit go-ahead.

## 3. Read the outputs locally

The run scripts and tests read the main root's Terraform outputs (`scripts/common.sh`), so
initialise the root once against the real backend. This only reads state; it does not apply.

```bash
cp infrastructure/terraform/environments/dev/backend.hcl.example \
   infrastructure/terraform/environments/dev/backend.hcl          # once; set the state bucket
terraform -chdir=infrastructure/terraform init -backend-config=environments/dev/backend.hcl
```

## 4. Load the data and run the pipeline

Olist: download `olistbr/brazilian-ecommerce` from Kaggle (`archive.zip`). TPC-H is generated
with DuckDB (`pip install duckdb`) because the brief's bucket is not readable from our account.

```bash
scripts/upload_olist_data.sh ~/Downloads/archive.zip   # zip or unzipped folder
scripts/copy_tpch_source.sh --generate 1               # TPC-H customer, 150,000 rows
scripts/run_raw_ingestion.sh --load-mysql              # load MySQL, MySQL + DataSync -> landing, landing -> raw
scripts/run_stream_ingestion.sh --count 500            # MSK stream -> landing -> raw
scripts/run_pipeline.sh --skip-ingest                  # raw -> transformed -> DataBrew gate -> curated -> crawlers -> Redshift
```

| Script | Notes |
| --- | --- |
| `run_raw_ingestion.sh` | `--load-mysql` reloads the Olist CSVs into MySQL first; later runs can skip it |
| `run_stream_ingestion.sh` | Starts the Glue streaming job, replays orders from the EC2 producer over SSM, stops the job, promotes the stream to raw. `--count 0 --rate 200` replays all 99,441 orders (about 394k events, ~35 minutes); `--offset N` continues a replay; `--keep-running` leaves the job on (2-hour timeout). Needs `python` with pip for the producer's packages |
| `run_pipeline.sh` | Starts Step Functions `lakehouse-dev-pipeline` and follows it. Without `--skip-ingest` it also runs MySQL -> landing and DataSync first. The stream is never part of it |
| `run_transformed.sh`, `run_curated.sh` | Run one stage by hand; `--tables a,b` for a subset. `run_curated.sh` also runs the crawlers and an Athena check |

Code changes to the Glue scripts or SQL reach AWS only through the pipeline (Terraform uploads
them), so push and approve before re-running.

## 5. Verify

```bash
pip install -r requirements.txt
LANDING_BUCKET=$(terraform -chdir=infrastructure/terraform output -raw landing_bucket_name) \
RAW_BUCKET=$(terraform -chdir=infrastructure/terraform output -raw raw_bucket_name) \
TRANSFORMED_BUCKET=$(terraform -chdir=infrastructure/terraform output -raw transformed_bucket_name) \
CURATED_BUCKET=$(terraform -chdir=infrastructure/terraform output -raw curated_bucket_name) \
  pytest tests/integration -v
```

Tests skip when a `<ZONE>_BUCKET` variable is not set. Then run the saved queries in the Athena
workgroup `lakehouse-dev-analytics` and `sql/redshift/03_analyst_queries.sql` in the Redshift
query editor (workgroup `lakehouse-dev-warehouse`).

## 6. Destroy (once, at the end)

```bash
aws codebuild start-build --project-name lakehouse-dev-destroy \
  --environment-variables-override name=CONFIRM_DESTROY,value=lakehouse-dev,type=PLAINTEXT
```

Then destroy the pipeline root by hand (`terraform -chdir=cicd/terraform destroy`), never before
the main root, because its CodeBuild role runs the main destroy. A new deploy after a destroy
needs the data uploaded again.

## Running cost (stack up)

Mainly MSK (2 x kafka.t3.small, about $70/month), 7 interface endpoints (about $50/month), RDS
(db.t4g.micro) and the producer (t4g.micro). Glue, DataSync, DataBrew and Redshift Serverless
bill per run or query; Redshift costs nothing while idle. The daily pipeline schedule is off
(`enable_pipeline_schedule = false`).

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Glue job hangs, then fails with a connection timeout | Missing VPC endpoint, or the Glue security group self-rule is missing |
| `AccessDenied` on a bucket from your own role | Your role is not in `admin_principal_arns` in `environments/dev/terraform.tfvars`; add it and push |
| Pipeline Apply fails with a stale plan | The state changed after the plan; release a new pipeline run |
| Lake Formation grant fails in Apply | The CodeBuild role is not a data lake admin; run `scripts/add_lake_formation_admin.sh` |
| `copy_tpch_source.sh` gets `AccessDenied` on `dory-public` | The bucket does not allow our account; use `--generate 1` |
| Landing -> raw: TPC-H in one column, or `_c0`... names in raw | Wrong `file_csv_delimiter` / `file_csv_header` / `file_source_format` in tfvars |
| Stream script stuck on "online in SSM" | Instance still booting, or an ssm/ssmmessages/ec2messages endpoint is missing |
| Pipeline stops at DataQuality | A DataBrew rule failed; the report is in `transformed/_dq_reports/<table>/` |

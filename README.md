# aws-lakehouse-data-analytics

A data lakehouse on AWS, built with Terraform for the Associate Program capstone. Three sources
land in S3, Glue jobs move the data through four zones, DataBrew checks quality before the
curated zone, and Athena and Redshift Spectrum query the result. A CodePipeline with OPA policy
checks deploys the infrastructure.

**Status:** all layers are built except the Data Exchange (Experian) feed, which is deferred.
Deployed and run end to end in dev on 2026-11-11, then destroyed; redeploy through the pipeline (see [cicd/README.md](cicd/README.md)).

## Architecture

```
RDS MySQL    ── Glue JDBC job ─────────> landing/rds/     CSV         ┐
S3 files     ── DataSync ──────────────> landing/files/   as copied   ├─ Glue ─> raw (Delta)
EC2 producer ── MSK ── Glue streaming ─> landing/stream/  JSON lines  ┘

raw ── Glue ─> transformed (Delta) + _dq/ Parquet snapshot
    ── DataBrew profile jobs + rulesets, dq_gate Lambda (any failed rule stops the run)
    ── Glue ─> curated (star schema + aggregates, Delta)
    ── Glue crawlers ─> Glue catalog ─> Athena
                                     └─> Redshift Spectrum ─> Redshift marts
```

- **Zones:** landing, raw, transformed, curated, one S3 bucket each (`sam-lakehouse-<zone>-<account>`).
- **Orchestration:** Step Functions `lakehouse-dev-pipeline` runs MySQL + DataSync ingest, landing
  -> raw, raw -> transformed, the DataBrew gate, curated, the crawlers and the Redshift load, and
  sends the result to SNS. The MSK stream runs separately (`scripts/run_stream_ingestion.sh`).
- **Governance:** Glue catalog databases per zone, Lake Formation grants, Athena workgroup with
  saved queries.
- **Security and monitoring:** one KMS key, private VPC with endpoints and no NAT, bucket policies
  that allow only named roles, AWS Config rules with auto-remediation, alerts to SNS
  `lakehouse-dev-alerts`.
- **CI/CD:** push to GitHub `main` -> plan + OPA checks -> manual approval -> apply.

Every service and connection in the landing and raw zones:
[docs/architecture/landing-raw-layer.md](docs/architecture/landing-raw-layer.md).

## Data

- [Olist Brazilian e-commerce](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)
  (Kaggle, CC BY-NC-SA 4.0, used for non-commercial training): 9 tables in MySQL, and order
  lifecycle events replayed into MSK.
- TPC-H customer on DataSync. The brief's bucket (`s3://dory-public/tpch/1000/customer`) is not
  readable from our account, so `scripts/copy_tpch_source.sh --generate 1` builds the same table
  with DuckDB.

## Repository layout

| Path | Holds |
| --- | --- |
| `infrastructure/terraform/` | Main Terraform root: `modules/`, `environments/dev/` (tfvars, backend) |
| `cicd/terraform/`, `cicd/buildspecs/` | Pipeline Terraform root and the plan / apply / destroy buildspecs |
| `opa/policies/`, `opa/tests/` | Conftest policies run on the Terraform plan, and their tests |
| `src/ingestion/` | Glue scripts per source (`mysql_rds/`, `kafka_streaming/`, `landing_to_raw/`) and the EC2 producer |
| `src/transformations/` | `raw_to_transformed/` and `transformed_to_curated/`: rules as plain DataFrame functions plus Glue entry scripts |
| `orchestration/` | Step Functions definition and the `dq_gate` Lambda |
| `sql/athena/`, `sql/redshift/` | Saved Athena queries; Spectrum schema, mart load and analyst queries |
| `scripts/` | Data upload and run helpers; `common.sh` holds the shared Terraform-output and Glue-run functions |
| `tests/unit/`, `tests/integration/` | Local PySpark tests of the rules; pytest checks against the deployed buckets and catalog |
| `docs/` | Architecture and deployment |

## Deploy

The main root is deployed only by the pipeline. Bootstrap the pipeline once, then every push
to `main` is planned, checked and applied after approval. Steps: [cicd/README.md](cicd/README.md),
summary with data loading: [docs/deployment/README.md](docs/deployment/README.md).

## Run the data pipeline

Run from Git Bash at the repo root, after the stack is deployed:

```bash
scripts/upload_olist_data.sh ~/Downloads/archive.zip   # Olist CSVs to the source-files bucket
scripts/copy_tpch_source.sh --generate 1               # TPC-H customer, 150,000 rows
scripts/run_raw_ingestion.sh --load-mysql              # MySQL + DataSync -> landing -> raw
scripts/run_stream_ingestion.sh --count 500            # MSK stream -> landing -> raw
scripts/run_pipeline.sh --skip-ingest                  # Step Functions: raw -> ... -> Redshift
```

`scripts/run_transformed.sh` and `scripts/run_curated.sh` run single stages by hand.

## Test

```bash
pip install -r requirements.txt
pytest tests/unit                                 # 22 tests, local PySpark
conftest verify -p opa/policies -p opa/tests      # 26 policy tests
pytest tests/integration                          # needs a deployed stack, see docs/deployment
```

## Destroy

Once, when the work is finished, with the manual CodeBuild project:

```bash
aws codebuild start-build --project-name lakehouse-dev-destroy \
  --environment-variables-override name=CONFIRM_DESTROY,value=lakehouse-dev,type=PLAINTEXT
```

## Docs

- [docs/deployment/README.md](docs/deployment/README.md) - deploy, load data, verify, destroy
- [docs/architecture/landing-raw-layer.md](docs/architecture/landing-raw-layer.md) - landing and raw services
- [docs/architecture/transformed-curated-analytics.md](docs/architecture/transformed-curated-analytics.md) - transformed, DataBrew gate, curated, Athena and Redshift
- [cicd/README.md](cicd/README.md) - pipeline, OPA policies, bootstrap

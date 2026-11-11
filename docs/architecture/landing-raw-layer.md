# Landing and raw zones: services and connections

This page covers the sources, the landing zone and the raw zone. The transformed and curated
zones, DataBrew, the catalog and the consumers are in
[transformed-curated-analytics.md](transformed-curated-analytics.md).
Everything here is created by `infrastructure/terraform`. Dev names are shown; `<acct>` is the
account ID.

## Data flow

```
  LANDING ZONE (glue-ingest-role, datasync-role)              LAKE HOUSE (glue-lakehouse-role)

source-files mysql_load/ --Glue loader job--> RDS MySQL (salesdb, 9 Olist tables)
RDS MySQL --Glue JDBC job (VPC)-------------> landing/rds/salesdb/<table>/ingest_date=D/   CSV         ┐
source-files files/ --DataSync--------------> landing/files/<dataset>/                     as copied   ├─ Glue landing -> raw ─> raw/<same path>/  Delta
EC2 producer -> MSK --Glue streaming job----> landing/stream/<topic>/ingest_date=D/        JSON lines  ┘
```

Every source lands in the landing bucket first, as delivered. One Glue job
(`landing_to_raw.py`) then writes the raw Delta tables. The two sides run as different IAM roles,
standing in for the brief's landing zone and lake house accounts: the ingest role can write
landing but not raw, and the lakehouse role can read landing and write raw.

The streaming job appends one JSON-lines micro-batch to landing every 60 seconds. The landing ->
raw job promotes the newest stream day already in raw again (it may have been cut off) and every
later landing day, so late events and days without a run still reach raw; `run_stream_ingestion.sh` runs it for the stream right after
the replay. Kafka offsets live in `s3://sam-lakehouse-glue-assets-<acct>/checkpoints/stream/<topic>/`,
so a restarted job continues where it stopped.

## Bucket layout

```
s3://sam-lakehouse-landing-<acct>/
  rds/<database>/<table>/ingest_date=YYYY-MM-DD/*.csv    full MySQL export per day
  stream/<topic>/ingest_date=YYYY-MM-DD/*.json           stream micro-batches (JSON lines)
  files/<dataset>/                                       files exactly as DataSync copied them (tpch_customer)

s3://sam-lakehouse-raw-<acct>/
  rds/<database>/<table>/                                Delta table, one per MySQL table
      _delta_log/                                        Delta transaction log
      ingest_date=YYYY-MM-DD/*.parquet                   data files
  files/<dataset>/                                       Delta table, one per file data set
  stream/<topic>/                                        Delta table, one per Kafka topic (append only)
```

Every raw row gets `_source_file`, `_ingested_at`, `_source`, `_raw_loaded_at` and the partition
column `ingest_date`. Raw keeps values as strings; types are applied in transformed. The landing
-> raw job writes one day per run (`--INGEST_DATE`, default today) and replaces only that day's
partition (`replaceWhere`), so raw keeps history and reruns are safe. `mergeSchema` lets new
source columns appear without failing the load. Stream batches can contain duplicates after a
failure; the transformed job removes them by `event_id`.

## Services

| Service | Resource (dev name) | Purpose |
| --- | --- | --- |
| KMS | key `alias/lakehouse-dev-data` | One customer-managed key, rotated, for buckets, RDS storage and secret, Glue logs and bookmarks, DataSync and MSK logs |
| VPC | `lakehouse-dev-vpc` 10.20.0.0/16, 3 private subnets, 1 route table | Private network for RDS, MSK, the producer and Glue (the third subnet is for Redshift). No internet gateway, no NAT |
| VPC endpoint (gateway) | `lakehouse-dev-s3-endpoint` | Private S3 access |
| VPC endpoints (interface) | glue, secretsmanager, kms, logs, ssm, ssmmessages, ec2messages (subnet 1 only) | Glue workers and the producer reach AWS APIs without internet; the ssm ones allow Run Command on the producer |
| Security groups | `lakehouse-dev-glue-sg`, `-rds-sg`, `-msk-sg`, `-producer-sg`, `-endpoints-sg` | Glue workers talk to each other; MySQL accepts 3306 only from Glue; MSK accepts 9098 only from Glue and the producer; the producer has no inbound; endpoints accept 443 from the VPC |
| S3 | `sam-lakehouse-landing-<acct>` | Landing zone |
| S3 | `sam-lakehouse-raw-<acct>` | Raw zone |
| S3 | `sam-lakehouse-source-files-<acct>` | Stands in for the outside world: `files/<dataset>/` (DataSync), `mysql_load/` (MySQL loader), `stream_replay/` (producer) |
| S3 | `sam-lakehouse-glue-assets-<acct>` | Glue scripts (`scripts/`), Spark temp files (`temp/`), stream checkpoints (`checkpoints/`), producer code and packages (`producer/`) |
| RDS | `lakehouse-dev-mysql` (MySQL 8.0, db.t4g.micro, private), subnet group, parameter group | The relational source; the parameter group forces TLS (`require_secure_transport=1`) |
| Secrets Manager | secret created by RDS (`manage_master_user_password`) | MySQL master credentials; never in code or state |
| IAM | `lakehouse-dev-glue-ingest-role` | Landing zone side: MySQL loader, MySQL export and streaming jobs. Writes landing `rds/` and `stream/`, reads `mysql_load/`, reads the topic, reads the RDS secret. No access to raw |
| IAM | `lakehouse-dev-glue-lakehouse-role` | Lake house side: landing -> raw (also transformed and curated). Reads landing, writes raw. No VPC, MySQL or MSK access |
| IAM | `lakehouse-dev-kafka-producer-role` + instance profile | EC2 producer: connect to MSK, create and write the one topic, read `producer/` and `stream_replay/`, SSM managed-instance policy |
| IAM | `lakehouse-dev-datasync-role` | DataSync: read the source prefix, write landing `files/` only |
| Glue | security configuration `lakehouse-dev-glue-security` | KMS for S3 writes, CloudWatch logs and job bookmarks |
| Glue | connection `lakehouse-dev-mysql` (JDBC) | URL, secret, subnet 1, `glue-sg` |
| Glue | job `lakehouse-dev-load-mysql-source-data` | Loads the 9 Olist CSVs from `mysql_load/` into MySQL (full reload); the only way data reaches the private RDS |
| Glue | job `lakehouse-dev-ingest-mysql-to-landing` | MySQL tables -> landing CSV (header, full extract per day, source columns only) |
| Glue | connection `lakehouse-dev-msk` (KAFKA) | Bootstrap brokers on 9098, TLS, SASL `AWS_MSK_IAM`, subnet 1, `glue-sg` |
| Glue | streaming job `lakehouse-dev-stream-msk-to-landing` (G.025X x2, 2 h timeout) | MSK topic -> landing JSON lines, 60 s windows |
| Glue | job `lakehouse-dev-landing-to-raw` | Landing (rds, files, stream) -> raw Delta; names the TPC-H columns of header-less files; `--SOURCES` and `--INGEST_DATE` per run |
| DataSync | 2 S3 locations + task `lakehouse-dev-files-to-landing` | Copies source-files `files/` -> landing `files/` (changed files only, verified) |
| MSK | cluster `lakehouse-dev-msk` (Kafka 3.8.x, 2 x kafka.t3.small, 10 GiB each) + configuration | The streaming source. KMS at rest, TLS in transit, IAM auth only, auto topic creation off |
| EC2 | `lakehouse-dev-kafka-producer` (t4g.micro, Amazon Linux 2023, private, IMDSv2, KMS root volume) | Stands in for the app that emits order events; runs `order_events_producer.py` over SSM |
| CloudWatch Logs | `/aws/datasync/lakehouse-dev`, `/aws/msk/lakehouse-dev` | DataSync transfer logs and MSK broker logs (KMS, 14 days) |

All Glue jobs run on Glue 4.0 with `--datalake-formats delta` where they write Delta.

## Connections

| From -> to | Network path | Identity |
| --- | --- | --- |
| Glue MySQL jobs -> RDS | The JDBC connection puts the job's ENIs in subnet 1 with `glue-sg`; `rds-sg` allows 3306 only from `glue-sg` | User and password from the RDS secret (`SECRET_ID` on the connection); TLS forced by the server |
| Glue (in VPC) -> Secrets Manager, Glue, KMS, Logs | Interface endpoints with private DNS | Glue role policy |
| Glue ingest jobs -> S3 | S3 gateway endpoint | Ingest role (prefix-scoped) + bucket allow-list |
| Glue landing -> raw job -> S3 | Glue's managed network (no VPC connection, S3 only) | Lakehouse role |
| DataSync -> source-files and landing | AWS service network | `datasync-role` on each S3 location; trust limited to our account's DataSync |
| Producer -> MSK | Subnet 1; `msk-sg` allows 9098 from `producer-sg` | Instance role signs an IAM token (`aws-msk-iam-sasl-signer`), TLS |
| Glue streaming job -> MSK | Connection `lakehouse-dev-msk` in subnet 1 with `glue-sg`; `msk-sg` allows 9098 from `glue-sg` | Ingest role via SASL `AWS_MSK_IAM`, TLS; read on the one topic only |
| You -> producer | SSM Run Command through the ssm endpoints; no SSH, no inbound rule | Your SSO role calls `ssm:SendCommand` |
| Producer -> S3 | S3 gateway endpoint | Producer role + bucket allow-list |
| You (CLI, console) -> buckets | Internet, TLS only | Your role must be in `admin_principal_arns` (tfvars) |

Every bucket policy denies non-TLS requests and every principal not on its allow-list. Each
allow-list holds the roles that bucket needs (for example: landing allows the two Glue roles and
DataSync; raw allows the lakehouse and crawler roles), the admin roles in
`admin_principal_arns`, the deployer (the role running Terraform, plus the CodeBuild role from
`deployer_principal_arns`), and the AWS Config service role and remediation role.

## Loading the data

- **MySQL (Olist):** `scripts/upload_olist_data.sh <archive.zip>` puts the 9 CSVs in
  `mysql_load/<table>.csv`; `scripts/run_raw_ingestion.sh --load-mysql` runs the loader job.
  Tables: `mysql_source_tables` in `variables.tf`.
- **Files (TPC-H):** `scripts/copy_tpch_source.sh --generate 1` builds TPC-H customer with DuckDB
  and uploads it to `files/tpch_customer/` (the brief's `s3://dory-public/tpch/1000/customer/` is
  not readable from our account). Data sets are listed in `file_datasets`; adding one is a new
  sub-folder plus a list entry, with no new DataSync task or job.
- **Stream (Olist):** `upload_olist_data.sh` also puts `stream_replay/olist_orders_dataset.csv`;
  `scripts/run_stream_ingestion.sh --count N` replays the lifecycle events (purchased, approved,
  shipped, delivered, canceled, unavailable) of N orders.

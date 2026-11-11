data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# The role behind the SSO/assumed-role session running Terraform, so the deployer is always in
# the bucket allow-lists and cannot lock itself out
data "aws_iam_session_context" "deployer" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name

  bucket_prefix = "${var.bucket_owner_prefix}-${var.project_name}"
  bucket_names = {
    for zone in ["landing", "raw", "transformed", "curated", "glue-assets", "source-files"] :
    zone => "${local.bucket_prefix}-${zone}-${local.account_id}"
  }

  # The source-files bucket stands in for the outside world: DataSync copies files/, the Glue
  # loader writes mysql_load/ into MySQL, and the EC2 producer replays stream_replay/
  source_mysql_load_prefix    = "mysql_load/"
  source_stream_replay_prefix = "stream_replay/"
  landing_files_prefix        = "files/"
  raw_files_delta_prefix      = "files/"

  catalog_database_prefix = replace(local.name_prefix, "-", "_")
  transformed_tables = [
    "customers", "sellers", "products", "geolocation", "orders", "order_items", "order_payments",
    "order_reviews", "order_events", "order_status_current", "tpch_customer",
  ]
  curated_tables = [
    "dim_date", "dim_geography", "dim_customer", "dim_seller", "dim_product",
    "fact_order_items", "fact_orders",
    "agg_daily_sales", "agg_seller_performance", "agg_delivery_performance",
    "agg_review_vs_delivery", "agg_tpch_customer_segment",
  ]

  admin_principal_arns = distinct(concat(
    [data.aws_iam_session_context.deployer.issuer_arn],
    var.admin_principal_arns,
    var.deployer_principal_arns,
  ))

  # AWS Config and the SSM remediation role read and fix bucket settings; the bucket policy
  # deny would otherwise block them
  bucket_service_principal_arns = [
    "arn:aws:iam::${local.account_id}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig",
    module.monitoring.remediation_role_arn,
  ]

  # Roles each bucket allows on top of the admins and the services above
  bucket_roles = {
    landing        = [module.iam.glue_ingest_role_arn, module.iam.glue_lakehouse_role_arn, module.iam.datasync_role_arn]
    raw            = [module.iam.glue_lakehouse_role_arn, module.iam.glue_crawler_role_arn]
    transformed    = [module.iam.glue_lakehouse_role_arn, module.iam.glue_crawler_role_arn, module.databrew.role_arn, module.orchestration.gate_role_arn]
    curated        = [module.iam.glue_lakehouse_role_arn, module.iam.glue_crawler_role_arn, module.redshift.role_arn]
    "glue-assets"  = [module.iam.glue_ingest_role_arn, module.iam.glue_lakehouse_role_arn, module.iam.producer_role_arn]
    "source-files" = [module.iam.datasync_role_arn, module.iam.glue_ingest_role_arn, module.iam.producer_role_arn]
  }
}

module "kms" {
  source = "./modules/kms"

  name_prefix = local.name_prefix
  account_id  = local.account_id
  region      = local.region
}

module "network" {
  source = "./modules/network"

  name_prefix                 = local.name_prefix
  region                      = local.region
  vpc_cidr                    = var.vpc_cidr
  private_subnet_cidrs        = var.private_subnet_cidrs
  interface_endpoint_services = var.interface_endpoint_services
}

module "iam" {
  source = "./modules/iam"

  name_prefix                 = local.name_prefix
  account_id                  = local.account_id
  region                      = local.region
  kms_key_arn                 = module.kms.key_arn
  landing_bucket_arn          = "arn:aws:s3:::${local.bucket_names["landing"]}"
  raw_bucket_arn              = "arn:aws:s3:::${local.bucket_names["raw"]}"
  transformed_bucket_arn      = "arn:aws:s3:::${local.bucket_names["transformed"]}"
  curated_bucket_arn          = "arn:aws:s3:::${local.bucket_names["curated"]}"
  glue_assets_bucket_arn      = "arn:aws:s3:::${local.bucket_names["glue-assets"]}"
  source_files_bucket_arn     = "arn:aws:s3:::${local.bucket_names["source-files"]}"
  enable_transformed_zone     = var.enable_transformed_zone
  enable_curated_zone         = var.enable_curated_zone
  catalog_database_prefix     = local.catalog_database_prefix
  rds_secret_arn              = module.rds_mysql.master_user_secret_arn
  source_files_prefix         = var.source_files_prefix
  source_mysql_load_prefix    = local.source_mysql_load_prefix
  source_stream_replay_prefix = local.source_stream_replay_prefix
  landing_files_prefix        = local.landing_files_prefix
  msk_cluster_arn             = module.msk.cluster_arn
  kafka_topic                 = var.kafka_topic
}

module "bucket" {
  source   = "./modules/s3"
  for_each = local.bucket_roles

  bucket_name            = local.bucket_names[each.key]
  kms_key_arn            = module.kms.key_arn
  allowed_principal_arns = concat(local.admin_principal_arns, local.bucket_service_principal_arns, each.value)
}

module "rds_mysql" {
  source = "./modules/rds-mysql"

  name_prefix        = local.name_prefix
  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [module.network.rds_security_group_id]
  kms_key_arn        = module.kms.key_arn
  engine_version     = var.mysql_engine_version
  instance_class     = var.mysql_instance_class
  db_name            = var.mysql_db_name
  master_username    = var.mysql_master_username
}

module "glue" {
  source = "./modules/glue"

  name_prefix              = local.name_prefix
  glue_version             = var.glue_version
  ingest_role_arn          = module.iam.glue_ingest_role_arn
  lakehouse_role_arn       = module.iam.glue_lakehouse_role_arn
  kms_key_arn              = module.kms.key_arn
  glue_assets_bucket_name  = module.bucket["glue-assets"].bucket_name
  source_files_bucket_name = module.bucket["source-files"].bucket_name
  landing_bucket_name      = module.bucket["landing"].bucket_name
  raw_bucket_name          = module.bucket["raw"].bucket_name
  transformed_bucket_name  = module.bucket["transformed"].bucket_name
  curated_bucket_name      = module.bucket["curated"].bucket_name
  subnet_id                = module.network.private_subnet_ids[0]
  availability_zone        = module.network.private_subnet_azs[0]
  security_group_id        = module.network.glue_security_group_id
  mysql_address            = module.rds_mysql.address
  mysql_port               = module.rds_mysql.port
  mysql_db_name            = module.rds_mysql.db_name
  mysql_secret_arn         = module.rds_mysql.master_user_secret_arn
  mysql_source_tables      = var.mysql_source_tables
  mysql_load_prefix        = local.source_mysql_load_prefix
  file_datasets            = var.file_datasets
  file_landing_prefix      = local.landing_files_prefix
  file_delta_prefix        = local.raw_files_delta_prefix
  file_source_format       = var.file_source_format
  file_csv_delimiter       = var.file_csv_delimiter
  file_csv_header          = var.file_csv_header
  msk_bootstrap_brokers    = module.msk.bootstrap_brokers_iam
  kafka_topic              = var.kafka_topic
  scripts_dir              = "${path.root}/../../src/ingestion"
  transformations_dir      = "${path.root}/../../src/transformations"
  enable_transformed_zone  = var.enable_transformed_zone
  enable_curated_zone      = var.enable_curated_zone
}

module "catalog" {
  source = "./modules/catalog"

  name_prefix                 = local.name_prefix
  database_prefix             = local.catalog_database_prefix
  crawler_role_arn            = module.iam.glue_crawler_role_arn
  security_configuration_name = module.glue.security_configuration_name
  kms_key_arn                 = module.kms.key_arn
  raw_bucket_name             = module.bucket["raw"].bucket_name
  transformed_bucket_name     = module.bucket["transformed"].bucket_name
  curated_bucket_name         = module.bucket["curated"].bucket_name
  results_bucket_name         = module.bucket["glue-assets"].bucket_name
  analyst_principal_arns      = var.admin_principal_arns
  spectrum_role_arn           = module.redshift.role_arn
  raw_table_paths = concat(
    [for table in var.mysql_source_tables : "rds/${var.mysql_db_name}/${table}"],
    [for dataset in var.file_datasets : "${local.raw_files_delta_prefix}${dataset}"],
    ["stream/${var.kafka_topic}"],
  )
  transformed_tables      = local.transformed_tables
  curated_tables          = local.curated_tables
  enable_transformed_zone = var.enable_transformed_zone
  enable_curated_zone     = var.enable_curated_zone
  sql_dir                 = "${path.root}/../../sql/athena"
}

module "datasync" {
  source = "./modules/datasync"

  name_prefix            = local.name_prefix
  account_id             = local.account_id
  region                 = local.region
  role_arn               = module.iam.datasync_role_arn
  kms_key_arn            = module.kms.key_arn
  source_bucket_arn      = module.bucket["source-files"].bucket_arn
  source_prefix          = var.source_files_prefix
  destination_bucket_arn = module.bucket["landing"].bucket_arn
  destination_prefix     = local.landing_files_prefix
}

module "msk" {
  source = "./modules/msk"

  name_prefix = local.name_prefix
  # One broker in each of the first two subnets; the third subnet is only for Redshift Serverless
  subnet_ids           = slice(module.network.private_subnet_ids, 0, 2)
  security_group_id    = module.network.msk_security_group_id
  kms_key_arn          = module.kms.key_arn
  kafka_version        = var.kafka_version
  broker_instance_type = var.msk_broker_instance_type
  broker_volume_size   = var.msk_broker_volume_size
}

module "kafka_producer" {
  source = "./modules/kafka-producer"

  name_prefix           = local.name_prefix
  instance_type         = var.producer_instance_type
  subnet_id             = module.network.private_subnet_ids[0]
  security_group_id     = module.network.producer_security_group_id
  instance_profile_name = module.iam.producer_instance_profile_name
  kms_key_arn           = module.kms.key_arn
}

# The producer downloads this at run time (scripts/run_stream_ingestion.sh), so edits need no new instance
resource "aws_s3_object" "producer_script" {
  bucket = module.bucket["glue-assets"].bucket_name
  key    = "producer/order_events_producer.py"
  source = "${path.root}/../../src/ingestion/kafka_streaming/order_events_producer.py"
  etag   = filemd5("${path.root}/../../src/ingestion/kafka_streaming/order_events_producer.py")
}

module "databrew" {
  source = "./modules/databrew"

  name_prefix             = local.name_prefix
  account_id              = local.account_id
  region                  = local.region
  transformed_bucket_name = local.bucket_names["transformed"]
  kms_key_arn             = module.kms.key_arn
}

module "redshift" {
  source = "./modules/redshift"

  name_prefix         = local.name_prefix
  account_id          = local.account_id
  region              = local.region
  vpc_id              = module.network.vpc_id
  subnet_ids          = module.network.private_subnet_ids
  kms_key_arn         = module.kms.key_arn
  curated_bucket_name = local.bucket_names["curated"]
  spectrum_database   = "${local.catalog_database_prefix}_spectrum"
  base_capacity       = var.redshift_base_capacity
}

module "monitoring" {
  source = "./modules/monitoring"

  name_prefix   = local.name_prefix
  bucket_prefix = local.bucket_prefix
  project_tag   = var.project_name
  account_id    = local.account_id
  region        = local.region
  kms_key_arn   = module.kms.key_arn
  alert_email   = var.alert_email
}

module "orchestration" {
  source = "./modules/orchestration"

  name_prefix                     = local.name_prefix
  account_id                      = local.account_id
  region                          = local.region
  kms_key_arn                     = module.kms.key_arn
  asl_path                        = "${path.root}/../../orchestration/step-functions/pipeline.asl.json"
  lambda_dir                      = "${path.root}/../../orchestration/lambda"
  sql_dir                         = "${path.root}/../../sql/redshift"
  ingest_job_name                 = module.glue.ingest_job_name
  datasync_task_arn               = module.datasync.task_arn
  landing_to_raw_job_name         = module.glue.landing_to_raw_job_name
  raw_to_transformed_job_name     = module.glue.raw_to_transformed_job_name
  transformed_to_curated_job_name = module.glue.transformed_to_curated_job_name
  databrew_jobs                   = module.databrew.profile_jobs
  databrew_job_arns               = module.databrew.profile_job_arns
  crawler_names                   = values(module.catalog.crawler_names)
  transformed_bucket_name         = local.bucket_names["transformed"]
  redshift_workgroup_name         = module.redshift.workgroup_name
  redshift_workgroup_arn          = module.redshift.workgroup_arn
  redshift_database               = module.redshift.database_name
  redshift_secret_arn             = module.redshift.admin_secret_arn
  redshift_role_arn               = module.redshift.role_arn
  spectrum_database               = module.catalog.spectrum_database
  alerts_topic_arn                = module.monitoring.alerts_topic_arn
  enable_schedule                 = var.enable_pipeline_schedule
}

locals {
  jdbc_url    = "jdbc:mysql://${var.mysql_address}:${var.mysql_port}/${var.mysql_db_name}"
  scripts_uri = "s3://${var.glue_assets_bucket_name}/scripts"

  common_job_arguments = {
    "--job-language"                     = "python"
    "--TempDir"                          = "s3://${var.glue_assets_bucket_name}/temp/"
    "--enable-continuous-cloudwatch-log" = "true"
    "--job-bookmark-option"              = "job-bookmark-disable"
  }

  # Glue's built-in Delta Lake support; the second --conf is chained inside the value,
  # which is how Glue documents passing more than one Spark setting.
  delta_job_arguments = {
    "--datalake-formats" = "delta"
    "--conf"             = "spark.sql.extensions=io.delta.sql.DeltaSparkSessionExtension --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.delta.catalog.DeltaCatalog"
  }

  scripts = {
    load   = "mysql_rds/load_olist_to_mysql.py"
    ingest = "mysql_rds/ingest_mysql_to_landing.py"
    stream = "kafka_streaming/stream_msk_to_landing.py"
    raw    = "landing_to_raw/landing_to_raw.py"
  }

  # Each job script imports its helper modules, which Glue puts on the Python path via --extra-py-files
  transformations_uri = "s3://${var.glue_assets_bucket_name}/scripts/transformations"
  transformed_script  = "raw_to_transformed/raw_to_transformed.py"
  transformed_libs = [
    "raw_to_transformed/olist_transforms.py",
    "raw_to_transformed/tpch_transforms.py",
    "raw_to_transformed/quality.py",
  ]
  curated_script = "transformed_to_curated/transformed_to_curated.py"
  curated_libs   = ["transformed_to_curated/curated_transforms.py"]

  transformation_files = concat(
    var.enable_transformed_zone ? concat([local.transformed_script], local.transformed_libs) : [],
    var.enable_curated_zone ? concat([local.curated_script], local.curated_libs) : [],
  )
}

resource "aws_glue_security_configuration" "this" {
  name = "${var.name_prefix}-glue-security"

  encryption_configuration {
    s3_encryption {
      s3_encryption_mode = "SSE-KMS"
      kms_key_arn        = var.kms_key_arn
    }

    cloudwatch_encryption {
      cloudwatch_encryption_mode = "SSE-KMS"
      kms_key_arn                = var.kms_key_arn
    }

    job_bookmarks_encryption {
      job_bookmarks_encryption_mode = "CSE-KMS"
      kms_key_arn                   = var.kms_key_arn
    }
  }
}

# TLS is forced server-side by require_secure_transport, so the URL needs no SSL options
resource "aws_glue_connection" "mysql" {
  name            = "${var.name_prefix}-mysql"
  connection_type = "JDBC"

  connection_properties = {
    JDBC_CONNECTION_URL = local.jdbc_url
    SECRET_ID           = var.mysql_secret_arn
  }

  physical_connection_requirements {
    subnet_id              = var.subnet_id
    availability_zone      = var.availability_zone
    security_group_id_list = [var.security_group_id]
  }
}

resource "aws_s3_object" "script" {
  for_each = local.scripts

  bucket = var.glue_assets_bucket_name
  key    = "scripts/${each.value}"
  source = "${var.scripts_dir}/${each.value}"
  etag   = filemd5("${var.scripts_dir}/${each.value}")
}

resource "aws_s3_object" "transformation" {
  for_each = toset(local.transformation_files)

  bucket = var.glue_assets_bucket_name
  key    = "scripts/transformations/${each.value}"
  source = "${var.transformations_dir}/${each.value}"
  etag   = filemd5("${var.transformations_dir}/${each.value}")
}

# Full rebuild each run; also writes the DataBrew snapshot (_dq/) and rejected rows (_quarantine/)
resource "aws_glue_job" "raw_to_transformed" {
  count = var.enable_transformed_zone ? 1 : 0

  name                   = "${var.name_prefix}-raw-to-transformed"
  description            = "Builds the transformed zone from raw (rules in src/transformations)"
  role_arn               = var.lakehouse_role_arn
  glue_version           = var.glue_version
  worker_type            = "G.1X"
  number_of_workers      = 2
  timeout                = 60
  security_configuration = aws_glue_security_configuration.this.name

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "${local.transformations_uri}/${local.transformed_script}"
  }

  default_arguments = merge(local.common_job_arguments, local.delta_job_arguments, {
    "--extra-py-files"     = join(",", [for lib in local.transformed_libs : "${local.transformations_uri}/${lib}"])
    "--RAW_BUCKET"         = var.raw_bucket_name
    "--TRANSFORMED_BUCKET" = var.transformed_bucket_name
    "--SOURCE_DATABASE"    = var.mysql_db_name
    "--TOPIC_NAME"         = var.kafka_topic
    "--TABLES"             = "all"
  })

  depends_on = [aws_s3_object.transformation]
}

resource "aws_glue_job" "transformed_to_curated" {
  count = var.enable_curated_zone ? 1 : 0

  name                   = "${var.name_prefix}-transformed-to-curated"
  description            = "Builds the curated star schema and aggregates from transformed"
  role_arn               = var.lakehouse_role_arn
  glue_version           = var.glue_version
  worker_type            = "G.1X"
  number_of_workers      = 2
  timeout                = 60
  security_configuration = aws_glue_security_configuration.this.name

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "${local.transformations_uri}/${local.curated_script}"
  }

  default_arguments = merge(local.common_job_arguments, local.delta_job_arguments, {
    "--extra-py-files"     = join(",", [for lib in local.curated_libs : "${local.transformations_uri}/${lib}"])
    "--TRANSFORMED_BUCKET" = var.transformed_bucket_name
    "--CURATED_BUCKET"     = var.curated_bucket_name
    "--TABLES"             = "all"
  })

  depends_on = [aws_s3_object.transformation]
}

# RDS is private, so a Glue job in the VPC is how the Olist tables get into MySQL
resource "aws_glue_job" "load_mysql" {
  name                   = "${var.name_prefix}-load-mysql-source-data"
  description            = "Loads the Olist CSVs from the source-files bucket into RDS MySQL"
  role_arn               = var.ingest_role_arn
  glue_version           = var.glue_version
  worker_type            = "G.1X"
  number_of_workers      = 2
  timeout                = 15
  connections            = [aws_glue_connection.mysql.name]
  security_configuration = aws_glue_security_configuration.this.name

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "${local.scripts_uri}/${local.scripts.load}"
  }

  default_arguments = merge(local.common_job_arguments, {
    "--JDBC_URL"      = local.jdbc_url
    "--SECRET_ARN"    = var.mysql_secret_arn
    "--SOURCE_BUCKET" = var.source_files_bucket_name
    "--LOAD_PREFIX"   = var.mysql_load_prefix
    "--TABLES"        = join(",", var.mysql_source_tables)
  })

  depends_on = [aws_s3_object.script]
}

resource "aws_glue_job" "ingest" {
  name                   = "${var.name_prefix}-ingest-mysql-to-landing"
  description            = "Exports RDS MySQL tables to landing as CSV"
  role_arn               = var.ingest_role_arn
  glue_version           = var.glue_version
  worker_type            = "G.1X"
  number_of_workers      = 2
  timeout                = 30
  connections            = [aws_glue_connection.mysql.name]
  security_configuration = aws_glue_security_configuration.this.name

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "${local.scripts_uri}/${local.scripts.ingest}"
  }

  default_arguments = merge(local.common_job_arguments, {
    "--CONNECTION_NAME" = aws_glue_connection.mysql.name
    "--SOURCE_DATABASE" = var.mysql_db_name
    "--SOURCE_TABLES"   = join(",", var.mysql_source_tables)
    "--LANDING_BUCKET"  = var.landing_bucket_name
  })

  depends_on = [aws_s3_object.script]
}

# --SOURCES and --INGEST_DATE can be overridden per run (e.g. only "stream")
resource "aws_glue_job" "landing_to_raw" {
  name                   = "${var.name_prefix}-landing-to-raw"
  description            = "Promotes landing (MySQL extracts, DataSync files, stream batches) to raw Delta tables"
  role_arn               = var.lakehouse_role_arn
  glue_version           = var.glue_version
  worker_type            = "G.1X"
  number_of_workers      = 2
  timeout                = 30
  security_configuration = aws_glue_security_configuration.this.name

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "${local.scripts_uri}/${local.scripts.raw}"
  }

  default_arguments = merge(local.common_job_arguments, local.delta_job_arguments, {
    "--LANDING_BUCKET"  = var.landing_bucket_name
    "--RAW_BUCKET"      = var.raw_bucket_name
    "--SOURCES"         = "rds,files,stream"
    "--INGEST_DATE"     = "today"
    "--SOURCE_DATABASE" = var.mysql_db_name
    "--SOURCE_TABLES"   = join(",", var.mysql_source_tables)
    "--TOPIC_NAME"      = var.kafka_topic
    "--DATASETS"        = join(",", var.file_datasets)
    "--LANDING_PREFIX"  = var.file_landing_prefix
    "--DELTA_PREFIX"    = var.file_delta_prefix
    "--SOURCE_FORMAT"   = var.file_source_format
    "--CSV_DELIMITER"   = var.file_csv_delimiter
    "--CSV_HEADER"      = tostring(var.file_csv_header)
  })

  depends_on = [aws_s3_object.script]
}

# Glue's Kafka source signs in to MSK with the job role (SASL/IAM over TLS)
resource "aws_glue_connection" "msk" {
  name            = "${var.name_prefix}-msk"
  connection_type = "KAFKA"

  connection_properties = {
    KAFKA_BOOTSTRAP_SERVERS = var.msk_bootstrap_brokers
    KAFKA_SSL_ENABLED       = "true"
    KAFKA_SASL_MECHANISM    = "AWS_MSK_IAM"
  }

  physical_connection_requirements {
    subnet_id              = var.subnet_id
    availability_zone      = var.availability_zone
    security_group_id_list = [var.security_group_id]
  }
}

# Bills while running: scripts/run_stream_ingestion.sh stops it, the timeout catches a forgotten run
resource "aws_glue_job" "stream" {
  name                   = "${var.name_prefix}-stream-msk-to-landing"
  description            = "Streams the MSK topic to landing as JSON lines"
  role_arn               = var.ingest_role_arn
  glue_version           = var.glue_version
  worker_type            = "G.025X"
  number_of_workers      = 2
  timeout                = 120
  connections            = [aws_glue_connection.msk.name]
  security_configuration = aws_glue_security_configuration.this.name

  command {
    name            = "gluestreaming"
    python_version  = "3"
    script_location = "${local.scripts_uri}/${local.scripts.stream}"
  }

  default_arguments = merge(local.common_job_arguments, {
    "--CONNECTION_NAME"     = aws_glue_connection.msk.name
    "--TOPIC_NAME"          = var.kafka_topic
    "--LANDING_BUCKET"      = var.landing_bucket_name
    "--CHECKPOINT_LOCATION" = "s3://${var.glue_assets_bucket_name}/checkpoints/stream/${var.kafka_topic}/"
    "--WINDOW_SIZE"         = "60 seconds"
  })

  depends_on = [aws_s3_object.script]
}

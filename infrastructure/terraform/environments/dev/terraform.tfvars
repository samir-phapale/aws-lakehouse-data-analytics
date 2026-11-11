aws_region          = "us-east-1"
project_name        = "lakehouse"
environment         = "dev"
bucket_owner_prefix = "sam"

enable_transformed_zone = true
enable_curated_zone     = true

# Daily 03:00 UTC run when true; otherwise run on demand with scripts/run_pipeline.sh
enable_pipeline_schedule = false
alert_email              = ""

admin_principal_arns = [
  "arn:aws:iam::899456967600:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_c4e4a4330ec2e1e2",
]
deployer_principal_arns = ["arn:aws:iam::899456967600:role/lakehouse-dev-cicd-deploy"]

mysql_instance_class = "db.t4g.micro"
mysql_db_name        = "salesdb"

# TPC-H customer from dbgen: pipe-delimited .tbl files without a header
file_datasets      = ["tpch_customer"]
file_source_format = "csv"
file_csv_delimiter = "|"
file_csv_header    = false

kafka_topic              = "order_events"
msk_broker_instance_type = "kafka.t3.small"
producer_instance_type   = "t4g.micro"

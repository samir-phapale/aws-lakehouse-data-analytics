# SSO admin role (IAM path included); stays in the artifacts bucket allow-list
deployer_admin_role_arn = "arn:aws:iam::899456967600:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_c4e4a4330ec2e1e2"

# Main root backend (same values as infrastructure/terraform/environments/dev/backend.hcl)
tf_state_bucket = "kafka-on-ec2-sam-24-09"
tf_state_key    = "lakehouse/dev/terraform.tfstate"

github_repository = "samir-phapale/aws-lakehouse-data-analytics"

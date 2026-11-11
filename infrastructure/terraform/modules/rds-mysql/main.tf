resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-mysql"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.name_prefix}-mysql"
  }
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name_prefix}-mysql8"
  family = "mysql8.0"

  parameter {
    name  = "require_secure_transport"
    value = "1"
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name_prefix}-mysql"
  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  db_name                       = var.db_name
  username                      = var.master_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  parameter_group_name   = aws_db_parameter_group.this.name
  vpc_security_group_ids = var.security_group_ids
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  deletion_protection        = false
  skip_final_snapshot        = true

  tags = {
    Name = "${var.name_prefix}-mysql"
  }
}

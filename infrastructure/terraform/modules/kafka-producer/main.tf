data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# No SSH: reached through SSM Run Command; deps and script come from S3 via the gateway endpoint
resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.al2023.insecure_value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  iam_instance_profile        = var.instance_profile_name
  associate_public_ip_address = false

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
    kms_key_id  = var.kms_key_arn
  }

  tags = {
    Name = "${var.name_prefix}-kafka-producer"
  }

  # A newer AMI should not replace a running producer
  lifecycle {
    ignore_changes = [ami]
  }
}

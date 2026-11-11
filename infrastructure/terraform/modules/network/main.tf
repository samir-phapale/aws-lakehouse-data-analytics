data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# No internet gateway or NAT: AWS services are reached through VPC endpoints only
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.name_prefix}-private-${count.index + 1}"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "glue" {
  name        = "${var.name_prefix}-glue-sg"
  description = "Glue job ENIs"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-glue-sg"
  }
}

# Glue requires a self-referencing rule so its workers can talk to each other
resource "aws_vpc_security_group_ingress_rule" "glue_self" {
  security_group_id            = aws_security_group.glue.id
  referenced_security_group_id = aws_security_group.glue.id
  ip_protocol                  = "tcp"
  from_port                    = 0
  to_port                      = 65535
  description                  = "Glue workers to each other"
}

resource "aws_vpc_security_group_egress_rule" "glue_all" {
  security_group_id = aws_security_group.glue.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound stays inside the VPC (no NAT); needed for endpoints and RDS"
}

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds-sg"
  description = "RDS MySQL source database"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-rds-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_glue" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.glue.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  description                  = "MySQL from Glue jobs only"
}

resource "aws_security_group" "endpoints" {
  name        = "${var.name_prefix}-endpoints-sg"
  description = "Interface VPC endpoints"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-endpoints-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS from inside the VPC"
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${var.name_prefix}-s3-endpoint"
  }
}

# One subnet only to keep dev cost down; the other AZs reach them cross-AZ
resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoint_services)

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private[0].id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.name_prefix}-${each.value}-endpoint"
  }
}

resource "aws_security_group" "msk" {
  name        = "${var.name_prefix}-msk-sg"
  description = "MSK brokers"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-msk-sg"
  }
}

resource "aws_security_group" "producer" {
  name        = "${var.name_prefix}-producer-sg"
  description = "EC2 Kafka producer (no inbound; managed through SSM)"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-producer-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "msk_from_clients" {
  for_each = {
    glue     = aws_security_group.glue.id
    producer = aws_security_group.producer.id
  }

  security_group_id            = aws_security_group.msk.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 9098
  to_port                      = 9098
  description                  = "Kafka SASL/IAM over TLS from ${each.key}"
}

resource "aws_vpc_security_group_egress_rule" "producer_all" {
  security_group_id = aws_security_group.producer.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound stays inside the VPC (no NAT); MSK, S3 and endpoints"
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "region" {
  description = "AWS region, used to build VPC endpoint service names"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs, one per AZ"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) >= 2
    error_message = "RDS needs subnets in at least two availability zones."
  }
}

variable "interface_endpoint_services" {
  description = "Short service names for interface endpoints (e.g. glue, logs)"
  type        = list(string)
}

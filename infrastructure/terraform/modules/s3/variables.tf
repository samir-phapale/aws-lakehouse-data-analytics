variable "bucket_name" {
  description = "Globally unique bucket name"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key used for default bucket encryption"
  type        = string
}

variable "allowed_principal_arns" {
  description = "IAM role ARNs allowed to use the bucket; every other principal is denied"
  type        = list(string)

  validation {
    condition     = length(var.allowed_principal_arns) > 0
    error_message = "At least one principal must be allowed, or the bucket becomes unreachable."
  }
}

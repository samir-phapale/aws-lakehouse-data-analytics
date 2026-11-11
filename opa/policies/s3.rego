package main

public_access_flags := ["block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"]

deny contains msg if {
	some rc in changes("aws_s3_bucket_server_side_encryption_configuration")
	some rule in rc.change.after.rule
	some enc in rule.apply_server_side_encryption_by_default
	enc.sse_algorithm != "aws:kms"
	msg := sprintf("%s: sse_algorithm is %q, must be \"aws:kms\"", [rc.address, enc.sse_algorithm])
}

# A rule block without a default-encryption block (or no rule at all) is not KMS either
deny contains msg if {
	some rc in changes("aws_s3_bucket_server_side_encryption_configuration")
	not unknown(rc, "rule")
	not has_kms_default(rc.change.after)
	msg := sprintf("%s: no apply_server_side_encryption_by_default with sse_algorithm \"aws:kms\"", [rc.address])
}

has_kms_default(after) if {
	some rule in after.rule
	some enc in rule.apply_server_side_encryption_by_default
	enc.sse_algorithm == "aws:kms"
}

deny contains msg if {
	some rc in changes("aws_s3_bucket_public_access_block")
	some flag in public_access_flags
	not rc.change.after[flag] == true
	msg := sprintf("%s: %s must be true", [rc.address, flag])
}

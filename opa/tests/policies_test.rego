# Run: conftest verify -p opa/policies -p opa/tests
package main

good_tags := {"Project": "lakehouse", "Environment": "dev", "ManagedBy": "terraform"}

# One resource change as `terraform show -json` writes it
rc(resource_type, after) := {
	"address": sprintf("%s.test", [resource_type]),
	"mode": "managed",
	"type": resource_type,
	"name": "test",
	"change": {"actions": ["create"], "after": after, "after_unknown": {}},
}

plan(changes) := {"format_version": "1.2", "resource_changes": changes}

no_denies(p) if count(deny) == 0 with input as p

denied_with(p, fragment) if {
	some msg in deny with input as p
	contains(msg, fragment)
}

sse(algorithm) := rc("aws_s3_bucket_server_side_encryption_configuration", {
	"bucket": "b",
	"rule": [{"apply_server_side_encryption_by_default": [{"sse_algorithm": algorithm, "kms_master_key_id": "k"}], "bucket_key_enabled": true}],
})

test_sse_kms_passes if no_denies(plan([sse("aws:kms")]))

test_sse_aes256_denied if denied_with(plan([sse("AES256")]), "must be \"aws:kms\"")

test_sse_without_default_block_denied if {
	denied_with(
		plan([rc("aws_s3_bucket_server_side_encryption_configuration", {"bucket": "b", "rule": [{"apply_server_side_encryption_by_default": []}]})]),
		"no apply_server_side_encryption_by_default",
	)
}

pab(restrict) := rc("aws_s3_bucket_public_access_block", {
	"bucket": "b",
	"block_public_acls": true,
	"block_public_policy": true,
	"ignore_public_acls": true,
	"restrict_public_buckets": restrict,
})

test_public_access_block_all_true_passes if no_denies(plan([pab(true)]))

test_public_access_block_flag_false_denied if denied_with(plan([pab(false)]), "restrict_public_buckets must be true")

iam(resource_type, statements) := rc(resource_type, {"name": "p", "policy": json.marshal({"Version": "2012-10-17", "Statement": statements})})

test_iam_scoped_actions_pass if {
	no_denies(plan([iam("aws_iam_role_policy", [
		{"Effect": "Allow", "Action": ["s3:GetObject", "kms:GenerateDataKey*"], "Resource": "arn:aws:s3:::b/*"},
		{"Sid": "GlueSecurityConfiguration", "Effect": "Allow", "Action": "glue:GetSecurityConfiguration", "Resource": "*"},
	])]))
}

test_iam_service_wildcard_list_denied if {
	denied_with(
		plan([iam("aws_iam_role_policy", [{"Sid": "TooBroad", "Effect": "Allow", "Action": ["s3:GetObject", "s3:*"], "Resource": "*"}])]),
		"wildcard action \"s3:*\"",
	)
}

test_iam_full_wildcard_string_denied if {
	denied_with(
		plan([iam("aws_iam_policy", [{"Effect": "Allow", "Action": "*", "Resource": "*"}])]),
		"wildcard action \"*\"",
	)
}

test_iam_single_statement_object_denied if {
	p := plan([rc("aws_iam_policy", {"policy": json.marshal({"Statement": {"Effect": "Allow", "Action": "glue:*", "Resource": "*"}})})])
	denied_with(p, "glue:*")
}

test_iam_deny_statement_with_wildcard_passes if {
	no_denies(plan([iam("aws_iam_role_policy", [{"Effect": "Deny", "Action": "s3:*", "Resource": "*"}])]))
}

test_iam_unknown_policy_skipped if {
	no_denies(plan([{
		"address": "aws_iam_role_policy.later",
		"mode": "managed",
		"type": "aws_iam_role_policy",
		"change": {"actions": ["create"], "after": {"name": "p"}, "after_unknown": {"policy": true}},
	}]))
}

test_glue_job_with_security_configuration_passes if {
	no_denies(plan([rc("aws_glue_job", {"name": "j", "security_configuration": "lakehouse-dev-glue"})]))
}

test_glue_job_without_security_configuration_denied if {
	denied_with(plan([rc("aws_glue_job", {"name": "j", "security_configuration": null})]), "security_configuration must be set")
}

db(encrypted, public) := rc("aws_db_instance", {"identifier": "db", "storage_encrypted": encrypted, "publicly_accessible": public})

test_db_encrypted_private_passes if no_denies(plan([db(true, false)]))

test_db_unencrypted_denied if denied_with(plan([db(false, false)]), "storage_encrypted must be true")

test_db_public_denied if denied_with(plan([db(true, true)]), "publicly_accessible must be false")

test_redshift_private_passes if {
	no_denies(plan([rc("aws_redshiftserverless_workgroup", {"workgroup_name": "w", "publicly_accessible": false})]))
}

test_redshift_public_denied if {
	denied_with(plan([rc("aws_redshiftserverless_workgroup", {"workgroup_name": "w", "publicly_accessible": true})]), "publicly_accessible must be false")
}

test_kms_rotation_on_passes if no_denies(plan([rc("aws_kms_key", {"enable_key_rotation": true, "tags_all": good_tags})]))

test_kms_rotation_off_denied if denied_with(plan([rc("aws_kms_key", {"enable_key_rotation": false})]), "enable_key_rotation must be true")

test_tags_complete_passes if no_denies(plan([rc("aws_sqs_queue", {"name": "q", "tags_all": good_tags})]))

test_tags_missing_managed_by_denied if {
	denied_with(
		plan([rc("aws_sqs_queue", {"name": "q", "tags_all": {"Project": "lakehouse", "Environment": "dev"}})]),
		"missing required tag \"ManagedBy\"",
	)
}

test_untaggable_resource_passes if no_denies(plan([rc("aws_s3_bucket_policy", {"bucket": "b", "policy": "{}"})]))

test_delete_and_noop_skipped if {
	deleted := object.union(db(false, true), {"change": {"actions": ["delete"], "after": null, "after_unknown": {}}})
	unchanged := object.union(db(false, true), {"change": {"actions": ["no-op"], "after": {"storage_encrypted": false, "publicly_accessible": true}, "after_unknown": {}}})
	no_denies(plan([deleted, unchanged]))
}

test_replacement_checked if {
	replaced := object.union(db(false, false), {"change": {"actions": ["delete", "create"], "after": {"storage_encrypted": false, "publicly_accessible": false}, "after_unknown": {}}})
	denied_with(plan([replaced]), "storage_encrypted must be true")
}

test_data_sources_skipped if {
	no_denies(plan([object.union(rc("aws_kms_key", {"enable_key_rotation": false}), {"mode": "data"})]))
}

package main

# The security configuration is what encrypts Glue S3 output, logs and bookmarks
deny contains msg if {
	some rc in changes("aws_glue_job")
	not unknown(rc, "security_configuration")
	not non_empty_string(rc.change.after.security_configuration)
	msg := sprintf("%s: security_configuration must be set", [rc.address])
}

non_empty_string(x) if {
	is_string(x)
	x != ""
}

deny contains msg if {
	some rc in changes("aws_db_instance")
	not rc.change.after.storage_encrypted == true
	msg := sprintf("%s: storage_encrypted must be true", [rc.address])
}

deny contains msg if {
	some rc in changes("aws_db_instance")
	rc.change.after.publicly_accessible == true
	msg := sprintf("%s: publicly_accessible must be false", [rc.address])
}

deny contains msg if {
	some rc in changes("aws_redshiftserverless_workgroup")
	rc.change.after.publicly_accessible == true
	msg := sprintf("%s: publicly_accessible must be false", [rc.address])
}

deny contains msg if {
	some rc in changes("aws_kms_key")
	not rc.change.after.enable_key_rotation == true
	msg := sprintf("%s: enable_key_rotation must be true", [rc.address])
}

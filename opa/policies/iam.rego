# No wildcard actions ("*" or "<service>:*") in Allow statements. Resource "*" is allowed (some
# actions, e.g. glue:GetSecurityConfiguration, have no resource-level scoping). Policies whose JSON
# is only known at apply time are skipped.
package main

iam_policy_types := ["aws_iam_role_policy", "aws_iam_policy"]

deny contains msg if {
	some resource_type in iam_policy_types
	some rc in changes(resource_type)
	is_string(rc.change.after.policy)
	doc := json.unmarshal(rc.change.after.policy)
	some statement in as_list(doc.Statement)
	statement.Effect == "Allow"
	some action in as_list(statement.Action)
	wildcard_action(action)
	msg := sprintf("%s: Allow statement %s grants wildcard action %q", [rc.address, statement_name(statement), action])
}

wildcard_action(action) if action == "*"

wildcard_action(action) if endswith(action, ":*")

statement_name(statement) := sprintf("%q", [statement.Sid]) if statement.Sid

statement_name(statement) := "(no Sid)" if not statement.Sid

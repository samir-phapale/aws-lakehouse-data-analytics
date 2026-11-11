# Helpers for the plan policies; input is `terraform show -json tfplan`.
# changes(): creates and updates only (a replacement counts as a create).
# present(): every resource that exists after apply, including no-ops.
package main

all_changes := [rc |
	some rc in input.resource_changes
	rc.mode == "managed"
	is_create_or_update(rc)
]

changes(resource_type) := [rc |
	some rc in all_changes
	rc.type == resource_type
]

present(resource_type) := [rc |
	some rc in input.resource_changes
	rc.mode == "managed"
	rc.type == resource_type
	rc.change.actions != ["delete"]
]

is_create_or_update(rc) if "create" in rc.change.actions

is_create_or_update(rc) if "update" in rc.change.actions

# The value is only known at apply time
unknown(rc, attr) if rc.change.after_unknown[attr] == true

as_list(x) := x if is_array(x)

as_list(x) := [x] if not is_array(x)

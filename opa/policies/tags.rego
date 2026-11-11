# Project tags come from provider default_tags. Resources without tags_all in the plan (not
# taggable, or tags known only at apply) are skipped.
package main

required_tags := ["Project", "Environment", "ManagedBy"]

deny contains msg if {
	some rc in all_changes
	tags := rc.change.after.tags_all
	is_object(tags)
	some key in required_tags
	not tags[key]
	msg := sprintf("%s: missing required tag %q", [rc.address, key])
}

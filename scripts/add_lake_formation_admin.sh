#!/usr/bin/env bash
# Adds a role as a Lake Formation data lake admin, keeping every other admin and setting. Needed
# once for the CodeBuild role (cicd/terraform output codebuild_role_arn) so the pipeline can manage
# the Lake Formation grants.
# Usage: scripts/add_lake_formation_admin.sh <role-arn>   (AWS_PROFILE default vr-sso, AWS_REGION default us-east-1)
set -euo pipefail
export MSYS_NO_PATHCONV=1

if [[ $# -ne 1 || "$1" != arn:aws:iam::*:role/* ]]; then
  echo "Usage: $0 <role-arn>   (e.g. arn:aws:iam::123456789012:role/lakehouse-dev-cicd-deploy)" >&2
  exit 1
fi

ROLE_ARN="$1"
PYTHON="${PYTHON:-python}"
AWS=(aws --profile "${AWS_PROFILE:-vr-sso}" --region "${AWS_REGION:-us-east-1}")

# Kept in variables, not temp files: the Windows aws/python executables cannot read Git Bash /tmp paths
CURRENT="$("${AWS[@]}" lakeformation get-data-lake-settings --output json)"

# Prints "present" if the ARN is already an admin, otherwise the full settings with it added
UPDATED="$(printf '%s' "$CURRENT" | "$PYTHON" -c '
import json, sys
role_arn = sys.argv[1]
settings = json.load(sys.stdin)["DataLakeSettings"]
admins = settings.setdefault("DataLakeAdmins", [])
if any(a.get("DataLakePrincipalIdentifier") == role_arn for a in admins):
    print("present")
else:
    admins.append({"DataLakePrincipalIdentifier": role_arn})
    print(json.dumps({"DataLakeSettings": settings}))
' "$ROLE_ARN")"

if [[ "$UPDATED" == "present" ]]; then
  echo "$ROLE_ARN is already a Lake Formation data lake admin; nothing changed."
  exit 0
fi

# put-data-lake-settings replaces the whole object, so it gets everything read above
"${AWS[@]}" lakeformation put-data-lake-settings --cli-input-json "$UPDATED"

echo "Added $ROLE_ARN as a Lake Formation data lake admin. Admins now:"
"${AWS[@]}" lakeformation get-data-lake-settings \
  --query 'DataLakeSettings.DataLakeAdmins[].DataLakePrincipalIdentifier' --output text | tr '\t' '\n'

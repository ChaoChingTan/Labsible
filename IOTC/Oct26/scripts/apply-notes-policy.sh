#!/bin/bash
# Apply the read-only file system policy to the lecture-notes EFS.
#
#   * Any NFS client that can reach a mount target (the Kali instances) gets
#     ClientMount only, which EFS treats as read-only.
#   * The notes admin role additionally gets ClientWrite and ClientRootAccess, so it
#     can publish notes. Without ClientRootAccess, root on the instance is squashed
#     and cannot write to the root-owned top level of the file system.
#
# This is a separate step because a policy inside the CloudFormation template
# cannot reference the file system's own ARN (circular reference).
# Safe to re-run. Requires the lab-storage stack to be deployed.
#
#   source params/lab.env && scripts/apply-notes-policy.sh
set -euo pipefail

PREFIX="${LAB_PREFIX:-lab}"
REGION="${AWS_REGION:?source params/lab.env first}"

x() {
  aws cloudformation list-exports --region "$REGION" \
    --query "Exports[?Name=='$1'].Value" --output text
}

FS_ID=$(x "${PREFIX}-NotesFileSystemId")
ROLE_ARN=$(x "${PREFIX}-NotesAdminRoleArn")
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[ -n "$FS_ID" ] && [ -n "$ROLE_ARN" ] || { echo "storage stack exports not found" >&2; exit 1; }

FS_ARN="arn:aws:elasticfilesystem:${REGION}:${ACCOUNT}:file-system/${FS_ID}"
POLICY=$(mktemp)
trap 'rm -f "$POLICY"' EXIT

cat > "$POLICY" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadOnlyForAllClients",
      "Effect": "Allow",
      "Principal": { "AWS": "*" },
      "Action": "elasticfilesystem:ClientMount",
      "Resource": "${FS_ARN}"
    },
    {
      "Sid": "WriteForNotesAdmin",
      "Effect": "Allow",
      "Principal": { "AWS": "${ROLE_ARN}" },
      "Action": ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite", "elasticfilesystem:ClientRootAccess"],
      "Resource": "${FS_ARN}"
    }
  ]
}
EOF

aws efs put-file-system-policy --region "$REGION" \
  --file-system-id "$FS_ID" --policy "file://${POLICY}" >/dev/null
echo "Applied read-only policy to ${FS_ID}"
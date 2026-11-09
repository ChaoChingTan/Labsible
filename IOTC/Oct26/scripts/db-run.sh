#!/bin/bash
# Run a database task on one web node through SSM, then restart Guacamole on all web nodes
# (not for dump). Run from your machine:
#
#   source params/lab.env && scripts/db-run.sh init
#   source params/lab.env && scripts/db-run.sh restore [dump-file-name]
#   source params/lab.env && scripts/db-run.sh dump
#   init-if-empty / restore-if-empty behave like init / restore but do nothing when the database
#   already has tables (used by spin-up.sh).
set -euo pipefail

PREFIX="${LAB_PREFIX:-lab}"
REGION="${AWS_REGION:?source params/lab.env first}"
MODE="${1:?usage: db-run.sh init|restore [key]|dump}"
KEY="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

x() { aws cloudformation list-exports --region "$REGION" \
        --query "Exports[?Name=='$1'].Value" --output text; }

BUCKET=$(x "${PREFIX}-DumpBucketName")
ADMIN_ARN=$(x "${PREFIX}-GuacAdminSecretArn")
ASG=$(x "${PREFIX}-WebAsgName")
[ -n "$BUCKET" ] && [ -n "$ADMIN_ARN" ] && [ -n "$ASG" ] || { echo "exports missing (platform/web stacks deployed?)" >&2; exit 1; }

IDS=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" --auto-scaling-group-names "$ASG" \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" --output text)
[ -n "$IDS" ] || { echo "no in-service web nodes" >&2; exit 1; }
FIRST=$(echo "$IDS" | awk '{print $1}')

run_on() {  # run_on "<instance ids>" "<shell command>"
  local params cid
  params=$(python3 -c 'import json,sys; print(json.dumps({"commands":[sys.argv[1]]}))' "$2")
  cid=$(aws ssm send-command --region "$REGION" --instance-ids $1 \
    --document-name AWS-RunShellScript --parameters "$params" \
    --query Command.CommandId --output text)
  for i in $1; do
    aws ssm wait command-executed --region "$REGION" --command-id "$cid" --instance-id "$i" || true
    aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$i" \
      --query "[Status,StandardOutputContent,StandardErrorContent]" --output text
    [ "$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$i" \
        --query Status --output text)" = Success ] || return 1
  done
}

B64=$(base64 -w0 "$HERE/node/db-node.sh")
CMD="echo $B64 | base64 -d > /tmp/db-node.sh && AWS_REGION=$REGION DUMP_BUCKET=$BUCKET GUAC_ADMIN_SECRET_ARN=$ADMIN_ARN bash /tmp/db-node.sh $MODE $KEY; rc=\$?; rm -f /tmp/db-node.sh; exit \$rc"

echo "Running '$MODE' on $FIRST"
run_on "$FIRST" "$CMD"

if [ "$MODE" != dump ]; then
  echo "Restarting Guacamole on: $IDS"
  run_on "$IDS" "docker restart guacamole"
fi
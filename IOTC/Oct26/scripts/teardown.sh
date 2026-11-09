#!/bin/bash
# Tear down a lab session safely.
#
#   source params/lab.env
#   scripts/teardown.sh --class PA31          # delete only PA31's stack (web and database stay up)
#   scripts/teardown.sh --class PA31 --class PA32
#   scripts/teardown.sh --all                 # dump the database, then delete every class stack,
#                                             # the web stack and the database stack
#   scripts/teardown.sh --all --dry-run       # show what would happen, change nothing
#   add --yes to skip the confirmation prompt
#   --skip-dump deletes the database WITHOUT dumping it (anything since the last dump is lost)
#
# --all dumps first and STOPS if the dump fails or does not produce a new, non-trivial file in
# S3, so students are never deleted without a saved copy. Order of deletion: class stacks, then
# lab-web, then lab-database (later stacks import values from the earlier ones). The permanent
# stacks (network, platform, storage) are never touched.
set -euo pipefail

PREFIX="${LAB_PREFIX:-lab}"
REGION="${AWS_REGION:?source params/lab.env first}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ALL="" ; YES="" ; DRY="" ; SKIPDUMP="" ; CLASSES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1; shift ;;
    --class) c="${2:?}"; c="${c^^}"
             [[ "$c" =~ ^PA3[123]$ ]] || { echo "class must be PA31, PA32 or PA33" >&2; exit 1; }
             CLASSES+=("$c"); shift 2 ;;
    --yes) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --skip-dump) SKIPDUMP=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
[ -n "$ALL" ] || [ "${#CLASSES[@]}" -gt 0 ] || { echo "give --all or at least one --class PAxx" >&2; exit 1; }
[ -z "$ALL" ] || [ "${#CLASSES[@]}" -eq 0 ] || { echo "use --all or --class, not both" >&2; exit 1; }

stack_status() {  # prints the status, or nothing if the stack does not exist
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null || true
}

# ---- what exists
if [ -n "$ALL" ]; then
  CLASSES=(PA31 PA32 PA33)
fi
CLASS_STACKS=()
for c in "${CLASSES[@]}"; do
  st=$(stack_status "${PREFIX}-class-${c,,}")
  if [ -n "$st" ] && [ "$st" != "None" ]; then CLASS_STACKS+=("${PREFIX}-class-${c,,}"); fi
done
WEB="" ; DB=""
if [ -n "$ALL" ]; then
  st=$(stack_status "${PREFIX}-web");      [ -n "$st" ] && [ "$st" != "None" ] && WEB="${PREFIX}-web"
  st=$(stack_status "${PREFIX}-database"); [ -n "$st" ] && [ "$st" != "None" ] && DB="${PREFIX}-database"
fi

if [ "${#CLASS_STACKS[@]}" -eq 0 ] && [ -z "$WEB" ] && [ -z "$DB" ]; then
  echo "nothing to tear down"; exit 0
fi

DO_DUMP=""
[ -n "$ALL" ] && [ -n "$WEB" ] && [ -n "$DB" ] && [ -z "$SKIPDUMP" ] && DO_DUMP=1
if [ -n "$DB" ] && [ -z "$DO_DUMP" ] && [ -z "$SKIPDUMP" ]; then
  echo "The database stack exists but the web stack does not, so it cannot be dumped (the dump runs on a web node)." >&2
  echo "Nothing was deleted. Deploy lab-web, restore or dump, then retry, or pass --skip-dump to delete the database anyway." >&2
  exit 1
fi

echo "Region: $REGION"
echo "Plan:"
[ -z "$DO_DUMP" ] || echo "  1. dump the database to S3 (stops here if it fails)"
[ -z "$SKIPDUMP" ] || echo "  (--skip-dump: the database will NOT be dumped; changes since the last dump are lost)"
for s in "${CLASS_STACKS[@]}"; do echo "  - delete $s (guacd pool, NLB and all Kali desktops in it)"; done
[ -z "$WEB" ] || echo "  - delete $WEB"
[ -z "$DB" ]  || echo "  - delete $DB (a final RDS snapshot is kept)"
echo "This ends every session on those stacks; students' files on the Kali desktops are lost."

if [ -n "$DRY" ]; then echo "dry run: nothing changed"; exit 0; fi
if [ -z "$YES" ]; then
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "cancelled"; exit 1; }
fi

# ---- dump first, and check it
if [ -n "$DO_DUMP" ]; then
  BUCKET=$(aws cloudformation list-exports --region "$REGION" \
    --query "Exports[?Name=='${PREFIX}-DumpBucketName'].Value" --output text)
  [ -n "$BUCKET" ] || { echo "dump bucket export not found; aborting" >&2; exit 1; }
  latest() { aws s3 ls "s3://$BUCKET/dumps/" --region "$REGION" | awk '{print $4}' | grep '\.sql\.gz$' | sort | tail -1 || true; }
  BEFORE=$(latest)
  echo "Dumping the database..."
  bash "$HERE/db-run.sh" dump || { echo "DUMP FAILED: nothing was deleted" >&2; exit 1; }
  AFTER=$(latest)
  [ -n "$AFTER" ] && [ "$AFTER" != "$BEFORE" ] || { echo "DUMP CHECK FAILED: no new dump file in S3; nothing was deleted" >&2; exit 1; }
  SIZE=$(aws s3api head-object --region "$REGION" --bucket "$BUCKET" --key "dumps/$AFTER" --query ContentLength --output text)
  [ "$SIZE" -ge 1000 ] || { echo "DUMP CHECK FAILED: $AFTER is only $SIZE bytes; nothing was deleted" >&2; exit 1; }
  echo "Dump saved: s3://$BUCKET/dumps/$AFTER ($SIZE bytes)"
fi

# ---- delete in order: classes (in parallel), web, database
del_wait() {
  aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$1" || {
    echo "DELETE DID NOT COMPLETE for $1 (status: $(stack_status "$1")). Check the stack events in the console." >&2
    exit 1; }
  echo "deleted $1"
}
for s in "${CLASS_STACKS[@]}"; do
  aws cloudformation delete-stack --region "$REGION" --stack-name "$s"
done
for s in "${CLASS_STACKS[@]}"; do del_wait "$s"; done
if [ -n "$WEB" ]; then aws cloudformation delete-stack --region "$REGION" --stack-name "$WEB"; del_wait "$WEB"; fi
if [ -n "$DB" ];  then aws cloudformation delete-stack --region "$REGION" --stack-name "$DB";  del_wait "$DB";  fi

# ---- leftovers
if [ -n "$DB" ]; then
  echo
  echo "RDS final snapshots left behind (they cost storage until deleted):"
  aws rds describe-db-snapshots --region "$REGION" --snapshot-type manual \
    --query "DBSnapshots[?contains(DBSnapshotIdentifier, '${PREFIX}-database')].[DBSnapshotIdentifier,SnapshotCreateTime]" --output table
  echo "Delete one with: aws rds delete-db-snapshot --region \"$REGION\" --db-snapshot-identifier <name>"
fi
echo "teardown complete"
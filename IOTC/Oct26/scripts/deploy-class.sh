#!/bin/bash
# Deploy or update one class stack (lab-class-<class>): the guacd pool, its NLB and one Kali
# per student index. The index list comes from Guacamole itself (every connection in the
# class), so it never depends on which roster file was synced last.
#
#   source params/lab.env
#   scripts/deploy-class.sh PA31                  # every student with a connection
#   scripts/deploy-class.sh PA31 --indexes 1,2,3  # only these (for tests)
#   scripts/deploy-class.sh PA31 --guacd-count 2  # fewer guacd nodes for a small test
#   scripts/deploy-class.sh PA31 --yes            # skip the confirmation prompt
#   scripts/deploy-class.sh PA31 --extra-script labs/web-sec.sh
#                                                 # optional lab-specific commands, run after kali-firstboot.sh
#
# Environment:
#   AWS_REGION, LAB_DOMAIN       from params/lab.env
#   LAB_KALI_AMI_ID              required: the golden Kali AMI for this lab
#   KALI_INSTANCE_TYPE           default t3.small
#   GUACD_INSTANCE_TYPE          default c6i.large
#   GUACD_COUNT                  default 3 (or --guacd-count N)
set -euo pipefail

CLASS="${1:?usage: deploy-class.sh PA31|PA32|PA33 [--indexes 1,2,3] [--yes]}"; shift
CLASS="${CLASS^^}"
[[ "$CLASS" =~ ^PA3[123]$ ]] || { echo "class must be PA31, PA32 or PA33" >&2; exit 1; }
INDEXES="" ; YES="" ; EXTRA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --indexes) INDEXES="${2:?}"; shift 2 ;;
    --yes) YES=1; shift ;;
    --guacd-count) GUACD_COUNT="${2:?}"; shift 2 ;;
    --extra-script) EXTRA="${2:?}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

REGION="${AWS_REGION:?source params/lab.env first}"
AMI="${LAB_KALI_AMI_ID:?set LAB_KALI_AMI_ID in params/lab.env}"
KALI_TYPE="${KALI_INSTANCE_TYPE:-t3.small}"
GUACD_TYPE="${GUACD_INSTANCE_TYPE:-c6i.large}"
GUACD_COUNT="${GUACD_COUNT:-3}"
[[ "$GUACD_COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "guacd count must be a positive number" >&2; exit 1; }
PREFIX="${LAB_PREFIX:-lab}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
STACK="${PREFIX}-class-${CLASS,,}"
OCTET="${CLASS:2}"

if [ -z "$INDEXES" ]; then
  INDEXES=$(python3 "$HERE/sync_guac.py" --list-class "$CLASS")
fi
[ -n "$INDEXES" ] || { echo "no connections found for $CLASS: run sync_guac.py first, or pass --indexes" >&2; exit 1; }
[[ "$INDEXES" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "bad index list: $INDEXES" >&2; exit 1; }
# CloudFormation cannot do arithmetic: pass the last octet (100 + index) directly.
COUNT=0 ; OCTETS=""
for i in ${INDEXES//,/ }; do
  [ "$i" -ge 1 ] && [ "$i" -le 154 ] || { echo "index $i out of range (1-154)" >&2; exit 1; }
  OCTETS="${OCTETS:+$OCTETS,}$((100 + i))" ; COUNT=$((COUNT + 1))
done

# kali-firstboot.sh (plus the optional extra script, appended and run in the same shell after it),
# compressed and base64-encoded: fits a CloudFormation parameter (4096 chars).
if [ -n "$EXTRA" ]; then
  [ -f "$EXTRA" ] || { echo "extra script not found: $EXTRA" >&2; exit 1; }
  BOOT=$(cat "$ROOT/ami/kali-firstboot.sh"; printf '\n# ---- extra script: %s ----\n' "$(basename "$EXTRA")"; cat "$EXTRA")
else
  BOOT=$(cat "$ROOT/ami/kali-firstboot.sh")
fi
PAYLOAD=$(printf '%s\n' "$BOOT" | gzip -9 -n -c | base64 -w0)
[ "${#PAYLOAD}" -le 4096 ] || { echo "boot payload too large (${#PAYLOAD} of 4096 chars); shorten the extra script" >&2; exit 1; }

echo "Stack:        $STACK ($REGION)"
echo "Kali desktops: $COUNT ($KALI_TYPE) from AMI $AMI"
echo "  indexes:    $INDEXES"
echo "  addresses:  10.0.$OCTET.x for x in $OCTETS  (10.0.$OCTET.(100+index))"
echo "  names:      ${CLASS,,}-<last octet>, for example ${CLASS,,}-${OCTETS%%,*}"
echo "guacd pool:   $GUACD_COUNT x $GUACD_TYPE behind 10.0.$OCTET.10:4822"
[ -z "$EXTRA" ] || echo "extra script: $EXTRA (payload ${#PAYLOAD} of 4096 chars)"

# User data only runs at an instance's first boot. Changing it on an existing stack replaces
# the Kali instances, which deletes whatever students have on them.
OLD=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Parameters[?ParameterKey=='KaliBootPayload'].ParameterValue" --output text 2>/dev/null || true)
if [ -n "$OLD" ] && [ "$OLD" != "None" ] && [ "$OLD" != "$PAYLOAD" ]; then
  echo
  echo "WARNING: the first-boot script differs from the one in the running stack."
  echo "         Deploying will REPLACE every Kali instance in $STACK (student files on them are lost)."
  read -r -p "Replace the Kali instances? [y/N] " ans2
  [[ "$ans2" =~ ^[Yy]$ ]] || { echo "cancelled"; exit 1; }
fi

if [ -z "$YES" ]; then
  read -r -p "Deploy? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "cancelled"; exit 1; }
fi

aws cloudformation deploy --region "$REGION" \
  --stack-name "$STACK" \
  --template-file "$ROOT/cfn/20-class.yaml" \
  --capabilities CAPABILITY_AUTO_EXPAND \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    LabPrefix="$PREFIX" ClassOctet="$OCTET" KaliHostOctets="$OCTETS" \
    KaliAmiId="$AMI" KaliInstanceType="$KALI_TYPE" KaliBootPayload="$PAYLOAD" \
    GuacdInstanceType="$GUACD_TYPE" GuacdMinSize="$GUACD_COUNT" GuacdMaxSize="$GUACD_COUNT"
echo "done: $STACK"
#!/bin/bash
# Kali first-boot configuration. Runs once as root from EC2 user-data (cloud-init).
# The class stack prepends a header that exports the inputs below, then this body.
#
# Inputs (environment):
#   KALI_PASSWORD  optional  default: kali. The desktop login is deliberately simple;
#                            the per-student Guacamole password is the gatekeeper and
#                            the client security group allows RDP from guacd only.
#   KALI_USER      optional  default: kali
#   EFS_ID         optional  e.g. fs-0123456789abcdef0 (enables the read-only notes mount)
#   REGION         optional  required together with EFS_ID
#
# Test on a throwaway instance:
#   sudo KALI_PASSWORD='test1234' EFS_ID='' REGION=ap-southeast-1 bash kali-firstboot.sh
set -u

KALI_PASSWORD="${KALI_PASSWORD:-kali}"
KALI_USER="${KALI_USER:-kali}"
LOG=/var/log/lab-firstboot.log
exec > >(tee -a "$LOG" /dev/console) 2>&1
echo "lab-firstboot: start $(date -u +%FT%TZ)"

# 1. Shared RDP password. Never echoed to the log.
echo "${KALI_USER}:${KALI_PASSWORD}" | chpasswd && echo "password set for ${KALI_USER}"

# 2. XFCE compositor off: fewer screen updates for guacd to re-encode.
XFWM_DIR="/home/${KALI_USER}/.config/xfce4/xfconf/xfce-perchannel-xml"
XFWM="${XFWM_DIR}/xfwm4.xml"
if [ -f "$XFWM" ]; then
  sed -i 's|\(name="use_compositing" type="bool" value="\)true|\1false|' "$XFWM"
else
  mkdir -p "$XFWM_DIR"
  cat > "$XFWM" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
XML
  chown -R "${KALI_USER}:${KALI_USER}" "/home/${KALI_USER}/.config"
fi
echo "compositor: $(grep -o 'use_compositing[^/]*' "$XFWM")"

# 3. Hostname from the instance's Name tag (needs instance metadata tags enabled).
TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)
if [ -n "$TOKEN" ]; then
  NAME=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/tags/instance/Name || true)
  if [[ "$NAME" =~ ^[A-Za-z0-9-]{1,63}$ ]]; then
    hostnamectl set-hostname "$NAME"
    grep -q "127.0.1.1 $NAME" /etc/hosts || echo "127.0.1.1 $NAME" >> /etc/hosts
    echo "hostname set to $NAME"
  else
    echo "hostname unchanged (no usable Name tag)"
  fi
fi

# 4. Read-only lecture notes from EFS. The write protection is enforced by the
#    EFS file system policy; "ro" here is only a convenience.
if [ -n "${EFS_ID:-}" ] && [ -n "${REGION:-}" ]; then
  MNT="/home/${KALI_USER}/Desktop/notes"
  mkdir -p "$MNT"
  if ! grep -q " ${MNT} " /etc/fstab; then
    echo "${EFS_ID}.efs.${REGION}.amazonaws.com:/ ${MNT} nfs4 nfsvers=4.1,ro,hard,timeo=600,retrans=2,noresvport,nofail,_netdev 0 0" >> /etc/fstab
  fi
  for i in $(seq 1 10); do
    if mount "$MNT"; then echo "notes mounted at $MNT"; break; fi
    echo "notes mount attempt $i failed, retrying"; sleep 6
  done
else
  echo "notes mount skipped (EFS_ID/REGION not set)"
fi

echo "lab-firstboot: done $(date -u +%FT%TZ)"
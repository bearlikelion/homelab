#!/usr/bin/env bash
# Attach the Synology iSCSI LUN and register it with Proxmox as an archive
# target.
#
# A directory storage on a formatted LUN rather than PVE's native iSCSI type:
# the link is a single 1GbE (~110 MB/s shared with everything else), which is
# fine for vzdump archives and ISOs and poor for live guest disks.
#
# Safe to re-run: every step is guarded, and it refuses to format a LUN that
# already carries a filesystem or an LVM signature.
#
#   scp scripts/pve-iscsi-synas.sh root@<host>:/tmp/
#   ssh root@<host> bash /tmp/pve-iscsi-synas.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Must run as root" >&2; exit 1; }

PORTAL=192.168.1.11
TARGET=iqn.2023-03.com.synas:iscsi
MOUNT=/mnt/synas
STORAGE=synas

echo "==> Discovery"
iscsiadm -m discovery -t sendtargets -p "$PORTAL" >/dev/null

# Survives a reboot without a unit of its own; open-iscsi logs in at boot.
echo "==> Login"
if iscsiadm -m session 2>/dev/null | grep -q "$TARGET"; then
  echo "    already logged in"
else
  iscsiadm -m node -T "$TARGET" -p "$PORTAL" --login
fi
iscsiadm -m node -T "$TARGET" -p "$PORTAL" --op update -n node.startup -v automatic

# by-path rather than /dev/sdX: the kernel hands out letters in probe order, so
# sdd today is sde after the next disk is added.
DEV="/dev/disk/by-path/ip-${PORTAL}:3260-iscsi-${TARGET}-lun-0"
echo "==> Waiting for $DEV"
for _ in $(seq 1 30); do [[ -e $DEV ]] && break; sleep 1; done
[[ -e $DEV ]] || {
  echo "LUN did not appear. Check that the Synology target's ACL permits" >&2
  echo "  $(awk -F= '/^InitiatorName/{print $2}' /etc/iscsi/initiatorname.iscsi)" >&2
  echo "in DSM under SAN Manager > Target > Edit > Initiators." >&2
  exit 1
}

REAL="$(readlink -f "$DEV")"
echo "    $DEV -> $REAL ($(blockdev --getsize64 "$REAL" | numfmt --to=iec))"

echo "==> Existing signatures"
SIG="$(blkid -p -o value -s TYPE "$REAL" 2>/dev/null || true)"
if [[ -n $SIG ]]; then
  if [[ $SIG == ext4 ]]; then
    echo "    ext4 already present; not reformatting"
  else
    echo "REFUSING TO FORMAT: $REAL already carries a '$SIG' signature." >&2
    echo "Inspect it before continuing; formatting would destroy it." >&2
    exit 1
  fi
else
  # 0% reserved: this holds backups, not a root filesystem, so handing 5% of the
  # LUN to root is pure waste.
  echo "    empty; creating ext4"
  mkfs.ext4 -m 0 -L synas "$REAL"
fi

echo "==> Mount"
mkdir -p "$MOUNT"
UUID="$(blkid -o value -s UUID "$REAL")"
# _netdev plus the open-iscsi dependency, or systemd tries to mount this before
# the network and the session exist, and the boot drops to emergency mode.
FSTAB_LINE="UUID=$UUID $MOUNT ext4 _netdev,x-systemd.requires=open-iscsi.service,nofail 0 2"
if grep -q "$UUID" /etc/fstab; then
  echo "    fstab entry already present"
else
  echo "$FSTAB_LINE" >> /etc/fstab
  systemctl daemon-reload
fi
mountpoint -q "$MOUNT" || mount "$MOUNT"

echo "==> Proxmox storage"
# is_mountpoint matters: without it, a LUN that fails to mount leaves PVE
# writing backups into the empty local directory and calling it a success.
if pvesm status --storage "$STORAGE" >/dev/null 2>&1; then
  echo "    storage '$STORAGE' already defined"
else
  pvesm add dir "$STORAGE" \
    --path "$MOUNT" \
    --content backup,iso,vztmpl \
    --is_mountpoint yes \
    --prune-backups 'keep-daily=7,keep-weekly=4,keep-monthly=6'
fi

echo "==> Result"
df -h "$MOUNT"
pvesm status --storage "$STORAGE"
echo "done"

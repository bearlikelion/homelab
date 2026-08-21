#!/usr/bin/env bash
# Prepare the tank datasets that the files container (190) shares over SMB.
#
# Runs on the PVE host, not in a container: acltype and snapdir are ZFS dataset
# properties the host owns, and the chown has to happen on the real UIDs rather
# than the shifted ones an unprivileged container sees.
#
# Safe to re-run: every step is guarded.
#
#   scp scripts/pve-share-prep.sh root@<host>:/tmp/
#   ssh root@<host> bash /tmp/pve-share-prep.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Must run as root" >&2; exit 1; }

MEDIA_ID=13000
# tank/backup is absent on purpose: it holds the restic repositories and the
# vzdump archives, and nothing that a desktop can write to should reach them.
DATASETS=(tank/media tank/documents tank/bulk tank/clips)

id -u mediauser >/dev/null 2>&1 || {
  echo "mediauser ($MEDIA_ID) missing. Run pve-bootstrap.sh first." >&2
  exit 1
}

echo "==> Datasets"
for ds in "${DATASETS[@]}"; do
  if zfs list -H -o name "$ds" >/dev/null 2>&1; then
    echo "    $ds exists"
  else
    echo "    $ds missing; creating"
    zfs create "$ds"
  fi
done

echo "==> ZFS properties"
for ds in "${DATASETS[@]}"; do
  # posixacl lets Samba store Windows ACLs; without it they degrade to mode bits.
  for prop in acltype=posixacl xattr=sa snapdir=visible; do
    name="${prop%%=*}"
    want="${prop#*=}"
    have="$(zfs get -H -o value "$name" "$ds")"
    if [[ $have == "$want" ]]; then
      echo "    $ds $name already $want"
    else
      echo "    $ds $name $have -> $want"
      zfs set "$prop" "$ds"
    fi
  done
done

echo "==> Ownership"
# The container's lxc.idmap passes 13000 through 1:1 and shifts everything else
# by 100000, so root-owned files arrive inside as nobody:nogroup and smbd cannot
# read them. media is already correct; documents and bulk are not.
for ds in "${DATASETS[@]}"; do
  mnt="$(zfs get -H -o value mountpoint "$ds")"
  owner="$(stat -c %u "$mnt")"
  if [[ $owner == "$MEDIA_ID" ]]; then
    echo "    $mnt already $MEDIA_ID"
    continue
  fi
  # Metadata only, but it walks every inode, so say so before a 414G dataset
  # goes quiet for a few minutes.
  echo "    $mnt owned by $owner; chown -R to $MEDIA_ID (this walks every inode)"
  chown -R "$MEDIA_ID:$MEDIA_ID" "$mnt"
  chmod 2775 "$mnt"
done

echo "==> Result"
for ds in "${DATASETS[@]}"; do
  mnt="$(zfs get -H -o value mountpoint "$ds")"
  printf "    %-18s " "$mnt"
  stat -c "%U:%G %a" "$mnt"
done

echo "done"

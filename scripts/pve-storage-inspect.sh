#!/usr/bin/env bash
# READ-ONLY inspection of the Proxmox host's storage.
#
# Creates nothing, formats nothing, mounts nothing. Run this before any storage
# work so we know what already exists and how much room is free.
#
#   scp scripts/pve-storage-inspect.sh root@<host>:/tmp/
#   ssh root@<host> bash /tmp/pve-storage-inspect.sh
set -uo pipefail

sec() { printf '\n=== %s ===\n' "$1"; }

sec "iSCSI sessions"
iscsiadm -m session 2>/dev/null || echo "no active sessions (PVE may attach on demand)"

sec "Block devices"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,WWN

sec "Physical volumes (which disk backs which VG)"
pvs -o pv_name,vg_name,pv_size,pv_free 2>/dev/null || echo "none"

sec "Volume groups: FREE space decides whether an LV can be carved"
vgs -o vg_name,vg_size,vg_free,lv_count 2>/dev/null || echo "none"

sec "Logical volumes: EXISTING DATA lives here"
lvs -o lv_name,vg_name,lv_size,lv_attr,pool_lv 2>/dev/null || echo "none"

sec "Filesystems present on LVs (blank fstype = unformatted)"
for lv in $(lvs --noheadings -o lv_path 2>/dev/null | tr -d ' '); do
  printf '  %-40s %s\n' "$lv" "$(blkid -o value -s TYPE "$lv" 2>/dev/null || echo '(none)')"
done

sec "Mounted real filesystems"
findmnt -t ext4,xfs,btrfs,zfs -o TARGET,SOURCE,FSTYPE,SIZE,USE%

sec "PVE storage config"
cat /etc/pve/storage.cfg

sec "PVE storage status"
pvsm_out=$(pvesm status 2>&1) && echo "$pvsm_out" || echo "$pvsm_out"

sec "Existing guests (a VG in use by these must not be touched)"
pct list 2>/dev/null || echo "no containers"
qm list 2>/dev/null || echo "no VMs"

sec "Build prerequisites"
printf 'lxc-pve:  '; dpkg-query -W -f='${Version}\n' lxc-pve 2>/dev/null || echo "not installed"
printf 'pve:      '; pveversion 2>/dev/null | head -1
printf 'render:   '; getent group render || echo "no render group"
printf 'kernel:   '; uname -r
echo "/dev/dri:"; ls -l /dev/dri 2>/dev/null || echo "  absent (no GPU passthrough available)"

sec "fstab entries for network storage (need _netdev)"
grep -vE '^\s*#|^\s*$' /etc/fstab || true

printf '\nRead-only inspection complete. Nothing was modified.\n'

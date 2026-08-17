#!/usr/bin/env bash
# Copy the Plex library off the NTFS iSCSI LUN onto the ZFS tank pool.
#
# Source stays mounted READ-ONLY throughout, so this cannot damage the original
# 6.6TB. Nothing is deleted; verify the copy before reclaiming anything.
#
# Downloads/ (360G) is deliberately skipped: it is likely already-imported
# duplicates, and copying it would push the pool to ~93% full where ZFS write
# performance degrades. TV+Movies+Concerts lands at ~78%.
#
# Run under tmux on the PVE host, since this takes hours:
#   tmux new -s migrate
#   bash /tmp/migrate-media.sh
#   ctrl-b d          detach
#   tmux a -t migrate reattach
set -euo pipefail

SRC=/mnt/plexmedia/Media
DST=/tank/media
MEDIA_UID=13000
MEDIA_GID=13000

# Source dir -> destination dir. Downloads intentionally absent.
declare -A LIBS=(
  [Concerts]=concerts
  [Movies]=movies
  [TV]=tv
)

[[ $EUID -eq 0 ]] || { echo "Must run as root" >&2; exit 1; }

# The source must be mounted read-only, or a bug here could damage the library.
if ! findmnt -n -o OPTIONS /mnt/plexmedia | grep -q '\bro\b'; then
  echo "REFUSING: /mnt/plexmedia is not mounted read-only." >&2
  echo "Remount with: mount -t ntfs3 -o remount,ro /dev/sdi2 /mnt/plexmedia" >&2
  exit 1
fi

command -v rsync >/dev/null || { echo "rsync not installed: apt install -y rsync" >&2; exit 1; }

echo "=== Space check ==="
avail=$(zfs list -H -p -o avail tank/media)
need=0
for s in "${!LIBS[@]}"; do
  b=$(du -sb "$SRC/$s" 2>/dev/null | cut -f1) || b=0
  need=$((need + b))
  printf '  %-10s %s\n' "$s" "$(numfmt --to=iec "$b")"
done
printf '  %-10s %s\n' "NEEDED" "$(numfmt --to=iec "$need")"
printf '  %-10s %s\n' "AVAIL" "$(numfmt --to=iec "$avail")"
if (( need > avail )); then
  echo "REFUSING: not enough free space." >&2
  exit 1
fi

echo
echo "=== Copying ==="
for src in "${!LIBS[@]}"; do
  dst="$DST/${LIBS[$src]}"
  echo
  echo "--- $src -> $dst ---"
  mkdir -p "$dst"
  # -a  preserve structure/timestamps      --partial  resume interrupted files
  # -H  preserve hardlinks within the set  --no-perms NTFS modes are meaningless
  # chown to the media user; NTFS reports everything as root.
  rsync -aH --partial --info=progress2 \
    --no-perms --no-owner --no-group \
    --chown="${MEDIA_UID}:${MEDIA_GID}" \
    "$SRC/$src/" "$dst/"
done

echo
echo "=== Fixing ownership and modes ==="
chown -R "${MEDIA_UID}:${MEDIA_GID}" "$DST"
# g+w so every media-group member can manage files; matches UMASK=002.
chmod -R a=,a+rX,u+w,g+w "$DST"

echo
echo "=== Verifying file counts ==="
rc=0
for src in "${!LIBS[@]}"; do
  s=$(find "$SRC/$src" -type f 2>/dev/null | wc -l)
  d=$(find "$DST/${LIBS[$src]}" -type f 2>/dev/null | wc -l)
  if [[ $s -eq $d ]]; then
    printf '  OK   %-10s %s files\n' "$src" "$s"
  else
    printf '  DIFF %-10s src=%s dst=%s\n' "$src" "$s" "$d"
    rc=1
  fi
done

echo
zfs list -o name,used,avail,refer tank/media
zpool list -o name,size,alloc,free,cap tank

echo
if [[ $rc -eq 0 ]]; then
  echo "Done. Counts match. Source is untouched at $SRC."
else
  echo "Done, but counts differ. Re-run to resume before trusting the copy." >&2
fi
exit $rc

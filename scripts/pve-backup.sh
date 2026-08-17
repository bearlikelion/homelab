#!/usr/bin/env bash
# Nightly backup, run on the PVE host by pve-backup.timer.
#
# Runs on the host and not in a container because the LXC disks are LVM-thin
# volumes the host owns; an unprivileged container cannot read them.
#
# Two stages:
#   1. vzdump every container to /tank/backup/dump   (restorable with pct restore)
#   2. restic those dumps plus /tank/documents and /etc/pve to Backblaze B2
#
# Credentials come from /etc/restic/b2.env, written by the pve_backup role.
set -euo pipefail

ENV_FILE=/etc/restic/b2.env
DUMP_DIR=/tank/backup/dump
LOCAL_REPO=/tank/backup/restic

# One run at a time. The first full backup takes hours, so without this the
# nightly timer starts a second copy on top of it, both fight for the same
# repository lock, and restic forget dies with "repository is already locked".
exec 9>/run/pve-backup.lock
flock -n 9 || { echo "another backup is already running; exiting"; exit 0; }

[ -r "$ENV_FILE" ] || { echo "missing $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

: "${RESTIC_PASSWORD:?}" "${B2_ACCOUNT_ID:?}" "${B2_ACCOUNT_KEY:?}" "${B2_BUCKET:?}"

log() { echo "[$(date -Is)] $*"; }

log "vzdump starting"
vzdump --all --mode snapshot --compress zstd --storage pve-backup --quiet 1

# /etc/pve is a FUSE mount, so copy it out before restic reads it.
log "copying /etc/pve"
PVE_COPY=/tank/backup/host-config/etc-pve-copy
mkdir -p "$PVE_COPY"
rsync -a --delete /etc/pve/ "$PVE_COPY/"

backup_to() {
  local repo="$1" label="$2"; shift 2
  log "restic backup -> $label"
  restic -r "$repo" backup --tag automated --exclude-caches "$@"

  # Retention is housekeeping: if it fails, say so but carry on, so a stale
  # lock cannot stop the offsite copy from running.
  log "restic forget -> $label"
  restic -r "$repo" forget \
    --tag automated \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
    --prune || log "WARNING: forget failed on $label, continuing"
}

# Local gets everything, including the vzdumps: restoring a container from
# tank is far faster than pulling it back from B2.
backup_to "$LOCAL_REPO" "local" \
  /tank/documents /tank/backup/dump /tank/backup/host-config

# Offsite gets the irreplaceable data plus the host config, but not the
# vzdumps. The containers are rebuildable from the repo with make apply-all,
# so shipping ~12G of rootfs archives offsite every night buys little and
# costs days on the initial upload.
backup_to "b2:$B2_BUCKET:server" "b2" \
  /tank/documents /tank/backup/host-config

log "done"

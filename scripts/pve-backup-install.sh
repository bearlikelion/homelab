#!/usr/bin/env bash
# Install the nightly backup job on the PVE host.
#
# The host is deliberately not in the Ansible inventory (it is the hypervisor,
# not a container), so this follows the same deploy-by-hand pattern as
# pve-bootstrap.sh:
#
#   scp scripts/pve-backup.sh scripts/pve-backup-install.sh root@<host>:/tmp/
#   ssh root@<host> B2_ACCOUNT_ID=... B2_ACCOUNT_KEY=... B2_BUCKET=... \
#       RESTIC_PASSWORD=... bash /tmp/pve-backup-install.sh
#
# Credentials are passed as environment variables so they never land in a file
# in the repo. They are written to /etc/restic/b2.env at 0600.
#
# Safe to re-run: every step is guarded.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Must run as root" >&2; exit 1; }
: "${B2_ACCOUNT_ID:?}" "${B2_ACCOUNT_KEY:?}" "${B2_BUCKET:?}" "${RESTIC_PASSWORD:?}"

echo "==> installing restic"
command -v restic >/dev/null || { apt-get update -qq && apt-get install -y restic; }
install -d -m 0700 /var/cache/restic

echo "==> writing /etc/restic/b2.env"
install -d -m 0700 /etc/restic
umask 077
cat > /etc/restic/b2.env <<EOF
RESTIC_PASSWORD=$RESTIC_PASSWORD
B2_ACCOUNT_ID=$B2_ACCOUNT_ID
B2_ACCOUNT_KEY=$B2_ACCOUNT_KEY
B2_BUCKET=$B2_BUCKET
EOF
chmod 0600 /etc/restic/b2.env

echo "==> installing /usr/local/sbin/pve-backup.sh"
install -m 0755 /tmp/pve-backup.sh /usr/local/sbin/pve-backup.sh

echo "==> initialising repositories"
set -a; . /etc/restic/b2.env; set +a
mkdir -p /tank/backup/restic
restic -r /tank/backup/restic cat config >/dev/null 2>&1 \
  || restic -r /tank/backup/restic init
restic -r "b2:$B2_BUCKET:server" cat config >/dev/null 2>&1 \
  || restic -r "b2:$B2_BUCKET:server" init

echo "==> installing systemd units"
cat > /etc/systemd/system/pve-backup.service <<'EOF'
[Unit]
Description=vzdump all guests, then restic to local and B2
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pve-backup.sh
# systemd gives the unit no HOME, so restic cannot find a cache directory and
# falls back to re-reading every file. Without this, each nightly run costs as
# much as the first one.
Environment=XDG_CACHE_HOME=/var/cache/restic
# Spinning disks: keep the backup off the media path's back.
IOSchedulingClass=idle
Nice=10
EOF

# 02:00 with a jitter, so it never collides with anything else on the hour.
cat > /etc/systemd/system/pve-backup.timer <<'EOF'
[Unit]
Description=Nightly backup

[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now pve-backup.timer

echo "==> done"
systemctl list-timers pve-backup.timer --no-pager

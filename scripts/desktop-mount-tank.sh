#!/usr/bin/env bash
# Mount the tank pool at /mnt/tank on a Linux desktop.
#
# Runs on the desktop, not on the server. Needs the Samba password for the user
# named in samba_users; it is written to a root-only credentials file rather
# than into /etc/fstab, which is world-readable.
#
# Safe to re-run: every step is guarded.
#
#   sudo bash scripts/desktop-mount-tank.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Must run as root (sudo)" >&2; exit 1; }

SERVER=192.168.1.190
SHARE=tank
MOUNT=/mnt/tank
CREDS=/etc/samba/credentials-tank
# The invoking user, not root: the mount should be owned by whoever ran sudo.
OWNER_UID="$(id -u "${SUDO_USER:-$USER}")"
OWNER_GID="$(id -g "${SUDO_USER:-$USER}")"

command -v mount.cifs >/dev/null || {
  echo "cifs-utils is not installed. On Arch: pacman -S cifs-utils" >&2
  exit 1
}

echo "==> Credentials"
if [[ -f $CREDS ]]; then
  echo "    $CREDS already exists; leaving it alone"
else
  mkdir -p "$(dirname "$CREDS")"
  read -rp "    Samba username: " SMB_USER
  read -rsp "    Samba password: " SMB_PASS; echo
  umask 077
  printf 'username=%s\npassword=%s\n' "$SMB_USER" "$SMB_PASS" > "$CREDS"
  chmod 600 "$CREDS"
fi

echo "==> Mount point"
mkdir -p "$MOUNT"

echo "==> fstab"
# x-systemd.automount so a server that is down does not stall boot, and the
# mount happens on first access instead. noauto pairs with it.
OPTS="credentials=${CREDS},uid=${OWNER_UID},gid=${OWNER_GID}"
OPTS="${OPTS},file_mode=0664,dir_mode=0775,iocharset=utf8,vers=3.1.1"
OPTS="${OPTS},_netdev,noauto,x-systemd.automount,x-systemd.idle-timeout=600"
LINE="//${SERVER}/${SHARE} ${MOUNT} cifs ${OPTS} 0 0"

if grep -q "[[:space:]]${MOUNT}[[:space:]]" /etc/fstab; then
  echo "    an entry for $MOUNT already exists; leaving it alone"
else
  echo "$LINE" >> /etc/fstab
  systemctl daemon-reload
fi

echo "==> Mounting"
mountpoint -q "$MOUNT" || mount "$MOUNT"

echo "==> Result"
findmnt "$MOUNT"
echo "    contents:"
ls -1 "$MOUNT" | sed 's/^/      /'
echo "done"

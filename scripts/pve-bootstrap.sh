#!/usr/bin/env bash
# Post-install setup for a fresh single-node Proxmox VE host.
#
# A stock install enables the enterprise repositories, which return 401 without
# a paid subscription, so apt fails before anything else can be done. This
# switches to the free no-subscription repo, disables Ceph, and upgrades.
#
# Safe to re-run: every step is guarded.
#
#   scp scripts/pve-bootstrap.sh root@<host>:/tmp/
#   ssh root@<host> bash /tmp/pve-bootstrap.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Must run as root" >&2; exit 1; }

# Derive the suite rather than hardcoding it, so this survives the next Debian
# release. PVE 9 is trixie.
SUITE="$(. /etc/os-release && echo "$VERSION_CODENAME")"
SRC=/etc/apt/sources.list.d
KEYRING=/usr/share/keyrings/proxmox-archive-keyring.gpg

echo "==> Proxmox bootstrap: suite=$SUITE"

[[ -f $KEYRING ]] || {
  echo "Missing $KEYRING. Older releases used a different name; check" >&2
  echo "ls /usr/share/keyrings/ | grep -i proxmox" >&2
  exit 1
}

# --- Enterprise repo -> no-subscription -------------------------------------
echo "==> Removing enterprise repositories"
rm -f "$SRC/pve-enterprise.sources" "$SRC/pve-enterprise.list"

# Only add ours if no definition exists already, otherwise apt warns that the
# target is "configured multiple times".
if grep -rqs "pve-no-subscription" "$SRC"/ /etc/apt/sources.list; then
  echo "==> pve-no-subscription already configured, leaving it alone"
else
  echo "==> Adding pve-no-subscription"
  cat > "$SRC/pve-no-subscription.sources" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $SUITE
Components: pve-no-subscription
Signed-By: $KEYRING
EOF
fi

# --- Ceph -------------------------------------------------------------------
# Ceph is distributed storage for multi-node clusters. On a single node with
# local disks it is unused, and its enterprise repo 401s the same way.
for f in "$SRC"/ceph.sources "$SRC"/ceph.list; do
  if [[ -f $f ]]; then
    echo "==> Disabling $(basename "$f")"
    mv "$f" "$f.disabled"
  fi
done

# --- Media identity and subuid/subgid ---------------------------------------
# Unprivileged containers shift IDs by 100000. Mapping host UID/GID 13000
# straight through needs an explicit allowance here, or the kernel rejects the
# lxc.idmap and the media files appear as nobody:nogroup inside the container.
# Terraform writes the lxc.idmap lines but cannot manage these files.
MEDIA_ID=13000
echo "==> Media user and subuid/subgid allowance"
groupadd -g "$MEDIA_ID" media 2>/dev/null || true
useradd -u "$MEDIA_ID" -g "$MEDIA_ID" -s /usr/sbin/nologin -M mediauser 2>/dev/null || true
for f in /etc/subuid /etc/subgid; do
  grep -q "^root:${MEDIA_ID}:1$" "$f" || echo "root:${MEDIA_ID}:1" >> "$f"
done

# --- Update -----------------------------------------------------------------
echo "==> apt update"
apt update

echo "==> apt full-upgrade"
apt full-upgrade -y

# --- Post-upgrade checks ----------------------------------------------------
# Docker inside an unprivileged LXC needs lxc-pve >= 6.0.5-2, which carries the
# fix for CVE-2025-52881. Without it containers fail with a permission error on
# net.ipv4.ip_unprivileged_port_start.
echo
echo "==> Checks"
printf 'lxc-pve:   '; dpkg-query -W -f='${Version}\n' lxc-pve 2>/dev/null || echo "not installed"
printf 'pve:       '; pveversion
printf 'render:    '; getent group render || echo "no render group"
printf 'kernel:    '; uname -r

echo
echo "Done. Reboot if the kernel was upgraded."

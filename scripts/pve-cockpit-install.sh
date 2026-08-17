#!/usr/bin/env bash
# Cockpit on the PVE host, for browsing every mounted filesystem from a browser.
#
# Proxmox's own UI only lists content-typed files (backups, ISOs, templates), so
# there is no way to see an arbitrary directory from it. Cockpit's Files app
# browses the real host filesystem, which is the only vantage point that sees
# the ZFS datasets, the container rootfs subvolumes and the iSCSI mount without
# any idmap translation.
#
# Deliberately NOT the `cockpit` metapackage: it recommends
# cockpit-networkmanager, and letting a web UI rewrite the networking on a host
# whose interfaces depend on the pinned nic0/nic1 names is how you lose remote
# access. See the network warning in docs/backups.md.
#
# Safe to re-run: every step is guarded.
#
#   scp scripts/pve-cockpit-install.sh root@<host>:/tmp/
#   ssh root@<host> bash /tmp/pve-cockpit-install.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Must run as root" >&2; exit 1; }

SUITE="$(. /etc/os-release && echo "$VERSION_CODENAME")"
BACKPORTS=/etc/apt/sources.list.d/${SUITE}-backports.sources
ORIGIN_HOST=cockpit.arneman.home
PVE_IP=192.168.1.99

# cockpit-files is not in trixie proper, only in backports. Backports is
# low-priority by default, so nothing else silently upgrades from it.
echo "==> Backports repository"
if [[ -f $BACKPORTS ]]; then
  echo "    $BACKPORTS already present"
else
  cat > "$BACKPORTS" <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: ${SUITE}-backports
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
fi
apt-get update -qq

echo "==> Packages"
# Explicit list, no recommends: no networkmanager, no packagekit.
apt-get install -y --no-install-recommends \
  cockpit-ws cockpit-bridge cockpit-system cockpit-storaged
apt-get install -y --no-install-recommends -t "${SUITE}-backports" cockpit-files

echo "==> Root login"
# Cockpit refuses root by default. The whole point here is browsing everything
# on the host, and every path outside /tank is root-owned.
DISALLOWED=/etc/cockpit/disallowed-users
mkdir -p /etc/cockpit
if [[ -f $DISALLOWED ]] && grep -qx root "$DISALLOWED"; then
  sed -i '/^root$/d' "$DISALLOWED"
  echo "    removed root from $DISALLOWED"
else
  echo "    root already permitted"
fi

echo "==> Reverse proxy config"
# Caddy terminates TLS and dials cockpit's own https. Without Origins, cockpit
# rejects the proxied websocket as a cross-origin request and the UI hangs on a
# blank page after login.
cat > /etc/cockpit/cockpit.conf <<EOF
[WebService]
Origins = https://${ORIGIN_HOST} https://${PVE_IP}:9090
ProtocolHeader = X-Forwarded-Proto
EOF

echo "==> Service"
systemctl enable --now cockpit.socket
systemctl restart cockpit.socket

echo "==> Result"
systemctl is-active cockpit.socket
ss -lnt | awk 'NR==1 || /:9090 /'
echo "    https://${ORIGIN_HOST}  (or https://${PVE_IP}:9090 directly)"
echo "    log in as root with the PVE host root password"
echo "done"

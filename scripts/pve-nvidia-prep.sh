#!/usr/bin/env bash
# Make the NVIDIA character devices exist before any container starts.
#
# Runs on the PVE host, not in a container: the kernel module and the device
# nodes belong to the host, and containers only ever get the nodes passed in.
#
# The driver creates /dev/nvidia0, /dev/nvidiactl and the uvm nodes lazily, on
# the first client that opens the GPU. Nothing opens it during boot, so a
# container with a dev0 entry pointing at /dev/nvidia0 starts before the node
# exists and comes up with no GPU at all. It works again after the first manual
# nvidia-smi, which is exactly the kind of "fixed itself" fault that wastes an
# evening. This installs a unit that creates the nodes early instead.
#
# Safe to re-run: every step is guarded.
#
#   scp scripts/pve-nvidia-prep.sh root@<host>:/tmp/
#   ssh root@<host> bash /tmp/pve-nvidia-prep.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Must run as root" >&2; exit 1; }

UNIT=/etc/systemd/system/nvidia-device-nodes.service

echo "==> Driver"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi missing. Install the proprietary driver on the host first." >&2
  exit 1
fi
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | sed 's/^/    /'

# The .run installer ships this; without it the nodes can only be created as a
# side effect of a full CUDA client starting.
echo "==> nvidia-modprobe"
if command -v nvidia-modprobe >/dev/null 2>&1; then
  echo "    present"
else
  echo "    missing; installing"
  apt-get install -y nvidia-modprobe
fi

echo "==> Unit"
# Before pve-guests.service, which is what starts containers marked onboot.
if [[ -f $UNIT ]]; then
  echo "    $UNIT already present"
else
  cat > "$UNIT" <<'EOF'
[Unit]
Description=Create NVIDIA device nodes
# The driver creates these on first use, which is too late for a container
# started by pve-guests with a dev0 entry pointing at them.
After=systemd-modules-load.service
Before=pve-guests.service

[Service]
Type=oneshot
RemainAfterExit=yes
# -c 0: the control and GPU 0 nodes. -u: the uvm nodes CUDA needs, and NVENC
# runs through a CUDA context.
ExecStart=/usr/bin/nvidia-modprobe -c 0 -u

[Install]
WantedBy=multi-user.target
EOF
  echo "    wrote $UNIT"
fi

systemctl daemon-reload
systemctl enable --now nvidia-device-nodes.service

echo "==> Result"
ls -l /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools 2>&1 |
  sed 's/^/    /'

cat <<'EOF'

The containers need the same driver version in userspace, installed with
--no-kernel-module. The clips role does that; it reads the version off this
host, so re-run the deploy after any driver upgrade or the container's
libnvidia-encode stops matching the kernel module and NVENC fails to open.
EOF

echo "done"

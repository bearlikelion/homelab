# Backups

Two tools, because they solve different problems.

## vzdump: restoring containers

`vzdump` is the only thing that produces a *restorable container*. Its
`.tar.zst` embeds the container config at `./etc/vzdump/pct.conf`, which carries
the parts that do not live inside the filesystem:

    unprivileged: 1
    mp0: /tank/media,mp=/data
    lxc.idmap: u 0 100000 13000
    lxc.idmap: u 13000 13000 1
    ...

A file-level backup of a container's rootfs captures none of that. Restoring
from one would mean rebuilding every container definition by hand.

Bind mounts are skipped automatically, so `/tank/media` (5.6T) is not dragged
into every archive:

    INFO: excluding bind mount point mp0 ('/data') from backup (not a volume)

Restore with:

    pct restore <vmid> /tank/backup/dump/dump/vzdump-lxc-<id>-<stamp>.tar.zst \
      --storage local-zfs

The storage name follows the root filesystem chosen at install: `local-zfs` on a
ZFS install, `local-lvm` on the older LVM-thin one. Check with `pvesm status`.

## restic: offsite copies

restic handles the data that has to survive the building, not just the disk:
`/tank/documents`, the vzdump output, and a copy of `/etc/pve`.

Two repositories, same contents:

| Repo | Location | Purpose |
|---|---|---|
| local | `/tank/backup/restic` | fast restores |
| b2 | `b2:<bucket>:server` | offsite |

Retention on both: 7 daily, 4 weekly, 6 monthly.

### Why not Borg

Borg speaks only SSH to a remote repo, so Backblaze B2 needs an rclone or fuse
shim in between. It also has no official web UI. restic has B2 as a native
backend and Backrest as a purpose-built UI. Duplicati was rejected outright
given its history of unrestorable repositories.

## Where things run, and why

The backup jobs run **on the PVE host**, not in the backup container. The LXC
disks are LVM-thin volumes owned by the host; an unprivileged container has no
access to host block devices and physically cannot read them.

The `backup` container (192.168.1.170) runs Backrest purely as a web UI at
`https://backup.arneman.home`, with `/tank` mounted **read-only** so a misclick
cannot destroy a repository.

The host is not in the Ansible inventory (it is the hypervisor, not a
container), so its half deploys by hand, same as `pve-bootstrap.sh`:

    scp scripts/pve-backup.sh scripts/pve-backup-install.sh root@<host>:/tmp/
    ssh root@<host> B2_ACCOUNT_ID=... B2_ACCOUNT_KEY=... B2_BUCKET=... \
        RESTIC_PASSWORD=... bash /tmp/pve-backup-install.sh

Runs nightly at 02:00 with a 30 minute jitter, at idle IO priority so it does
not fight Plex for the spindles.

## Secrets

`restic_password` lives in `ansible/group_vars/all/secrets.sops.yml`, not on the
host. A repository password that only exists on the machine being reinstalled
cannot be used to restore that machine.

Losing `restic_password` means losing every offsite backup. restic cannot
decrypt a repository without it.

## Restoring after a Proxmox reinstall

1. Physically disconnect the four tank disks before installing. The installer
   offers them as targets and wipes whatever is selected. Identify them by
   serial, not by `sdX`, which shifts when disks move:
   `ZFN33NL9`, `ZFN33C8C`, `ZFN33CFY`, `ZFN33EFW`.
2. Install PVE on the two Intel SSDs (`PHDV638402EQ480BGN`,
   `PHDV645102F4480BGN`) as `zfs (RAID1)`, booting the installer in **UEFI**
   mode. See "Boot mode" below.
3. Reconnect the tank disks, then:

       zpool import -f tank
       zpool set cachefile=/etc/zfs/zpool.cache tank

   Without the cachefile the pool imports by hand but vanishes on reboot.
4. Run `scripts/pve-bootstrap.sh` to recreate the `mediauser` (13000) identity
   and the `root:13000:1` subuid/subgid entries the idmaps depend on. This must
   happen **before** any `pct restore`: without it the containers come up with
   `/data` owned by `nobody:nogroup`. Verify with `ls -ld /data` inside 110,
   which should show `mediauser media`.
5. Rebuild from code where possible: `make apply-all && make deploy`.
6. Use `pct restore` for runtime state code cannot recreate: Plex metadata,
   the Postiz database, Caddy's certificates in `/opt/edge/caddy-data`.
7. Reinstall the backup stack. It lives on the root disk and does not survive
   the reinstall: no `pve-backup.sh`, no timer, no `/etc/restic/b2.env`. Until
   this is done there are **no nightly backups**. See "Where things run" above
   for the two commands; the existing B2 repository is picked up by the same
   `restic_password`.

### Boot mode

Install in UEFI, with CSM disabled and Secure Boot off. With ZFS root,
`proxmox-boot-tool` maintains an ESP on **both** mirror members, so either disk
boots alone; the Legacy BIOS path is less well tested and the second disk's
bootloader tends to be the thing found broken later. Confirm afterwards:

    proxmox-boot-tool status    # expect both UUIDs listed as uefi

Hand ZFS the raw disks. Do not build a mirror on the MegaRAID 9260-8i at
`82:00.0` first: hardware RAID hides the individual disks and defeats ZFS
checksum repair. The 9211-8i (IT mode) and the onboard AHCI ports are fine.

With Secure Boot off, `apt` may fail to configure `shim-signed`, whose
maintainer script aborts when the firmware exposes no `SetupMode` variable:

    Failed to read "SetupMode" variable: No such file or directory

It is unused in this configuration; `apt remove shim-signed` and carry on.

### Network warning

`/etc/network/interfaces` references bonded interfaces named `nic0` and `nic1`.
Nothing on the old install created those names: no `.link` file, no udev rule,
and `/etc/pve/mapping` was empty. They came from the installer's naming at the
time, which does not reproduce on a fresh install. The NICs come up as
`enp2s0f0`/`enp2s0f1` instead, the bond does not form, and the host is
**unreachable over the network**.

The hardware is an Intel I350 dual port (`igb`) on the X10DRW-i:

| Name | PCI | MAC |
|---|---|---|
| nic0 | `0000:02:00.0` | `00:25:90:92:ff:64` |
| nic1 | `0000:02:00.1` | `00:25:90:92:ff:65` |

Pin the names by MAC to make the old `interfaces` file work unchanged. The two
`.link` files are versioned in `files/systemd-network/` and mirrored to
`/tank/backup/host-config/systemd-network/`, since a copy that only exists on
`tank` is no use if `tank` is what failed. From the console after the install:

    cp /tank/backup/host-config/systemd-network/*.link /etc/systemd/network/
    update-initramfs -u -k all
    reboot

Still have console or IPMI access on hand for the first boot, since the copy
happens before the network works. `ip-br-link.txt`, `netdev-macs.txt` and
`interfaces.txt` in `/tank/backup/host-config/` record the expected state.

## Not covered

`/tank/media` (5.6T) is not backed up anywhere. It is replaceable; the 416G in
`/tank/documents` is not. Mirrors protect against a disk failing, not against a
deletion or a fire.

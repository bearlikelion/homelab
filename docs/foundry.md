# Foundry VTT

Foundry runs in the `foundry` LXC (240, `192.168.1.240`) and is public at `https://foundry.arneman.me`.
It reaches the internet the same way Penpot does: Cloudflare, the GCP node, the WireGuard tunnel, then Caddy on `edge`; see [tunnel.md](tunnel.md).

The `foundry` role runs the `felddy/foundryvtt` image, pinned in `ansible/group_vars/all/main.yml`.
The image does not contain Foundry itself.
On first start it signs in to foundryvtt.com with your account and downloads the licensed build into `/opt/foundry/data/container_cache`.

## First deploy

Add three values to the encrypted secrets before deploying:

    sops ansible/group_vars/all/secrets.sops.yml

- `foundry_username` and `foundry_password`: your foundryvtt.com account.
- `foundry_admin_key`: the password for Foundry's setup screen. The container rewrites it on every start, so change it here, not in the UI.

Then build and configure the guest:

    make plan
    make apply
    make deploy

The first start downloads the distribution before it listens, so allow a few minutes.
Open `https://foundry.arneman.me`, enter the admin key, accept the license, and create or install worlds.

## Adding campaign files

Foundry's data directory is shared over Samba inside the existing `tank` share:

- Windows: `\\files\tank\foundry` (or `\\192.168.1.190\tank\foundry`)
- Linux: `/mnt/tank/foundry`, once `scripts/desktop-mount-tank.sh` has run

Drop files into the matching folder under `Data`:

| Folder | Holds |
|---|---|
| `Data/worlds` | campaigns, one folder per world |
| `Data/modules` | modules and adventure packs |
| `Data/systems` | game systems |
| anything else under `Data`, e.g. `Data/assets` | maps, tokens, audio |

Unzip packs so each world, module or system is its own folder containing its `world.json`, `module.json` or `system.json`.
Foundry picks new worlds, modules and systems up when you return to the setup screen; assets are usable immediately.
Files copied this way skip Cloudflare's 100 MB upload limit, so this is the way to bring in large map or audio packs.

Everything is owned by `mediauser` (13000): Foundry runs as that uid and Samba writes as it, so no ownership fixes are ever needed.

## Data and backups

Everything lives on the host's `fast/foundry` dataset (`/fast/foundry`), bind-mounted into `foundry` at `/opt/foundry/data` and into `files` at `/srv/samba/tank/foundry`.
vzdump skips bind mounts, so `scripts/pve-backup.sh` backs `/fast/foundry` up with restic, locally and to B2.

Rebuilding guest 240 leaves the campaigns untouched; `make apply` and `make deploy` bring Foundry back on top of the same data.

## Upgrades

Change `foundry_image` to the new tag and run `make deploy`.
Back up the guest first: a major Foundry version migrates worlds in place, and they cannot be opened by the old version afterwards.

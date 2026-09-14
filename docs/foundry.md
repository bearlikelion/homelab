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

## Data and backups

Worlds, systems, modules and uploaded assets live in `/opt/foundry/data`, a directory on the guest's root filesystem rather than a bind mount, so the nightly vzdump archive captures them.
For a full recovery, restore guest 240 from its vzdump archive.

Cloudflare's free plan rejects request bodies over 100 MB, so upload large maps or audio packs from the LAN (`http://192.168.1.240:30000`) instead of the public name.

## Upgrades

Change `foundry_image` to the new tag and run `make deploy`.
Back up the guest first: a major Foundry version migrates worlds in place, and they cannot be opened by the old version afterwards.

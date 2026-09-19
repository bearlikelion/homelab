# server

A home Proxmox host, written down as code. OpenTofu builds the containers,
Ansible fills them, and a Makefile drives both. Nothing here is clicked into
existence in a web UI, so the whole setup can be torn down and rebuilt from
this repository.

## How it fits together

Two layers, kept apart on purpose:

- **OpenTofu** (`live/`, `modules/`) creates the guests on Proxmox: cores, memory, disks, bind mounts, network.
  It owns the boxes.
  Almost all of them are LXC containers; `pelican` is a full KVM machine, because the game server daemon it runs is unsupported in one.
- **Ansible** (`ansible/`) installs Docker and renders a Compose file into each
  one. It owns what runs inside them.

Splitting them means a service can be redeployed all day without ever touching
the container definition, and a container can be resized without redeploying
the service.

## What runs where

| Guest | What it does |
|---|---|
| `media` | Radarr, Sonarr, Prowlarr, qBittorrent, Tautulli, Maintainerr |
| `plex` | Plex Media Server, the only service published to the internet |
| `edge` | Caddy reverse proxy, AdGuard Home for DNS, a dashboard, dynamic DNS |
| `vpn` | OpenVPN Access Server, the way in to everything else |
| `build` | Compiles Godot on 24 cores so a laptop does not have to, and runs the Forgejo Actions runner |
| `code` | Forgejo, the git server and CI backend behind `code.arneman.home` |
| `design` | Penpot, the design and prototyping workspace, public through the GCP tunnel |
| `foundry` | Foundry VTT, public through the GCP tunnel |
| `clips` | Fireshare, game clips shared by link, transcoding on the P400 |
| `darkfall` | The Darkfall server cluster, plus the CI build rack on the mesh |
| `pelican` | Pelican panel and Wings, SteamCMD game servers in Docker. The one VM |
| `azcore` | AzerothCore, a private WotLK server built by CI on `build`. Stopped for now |
| `vmangos` | vMaNGOS, a private vanilla server built on the workstation |
| `social` | Postiz |
| `backup` | Backrest over restic, nightly to local disk and offsite to B2 |
| `files` | Samba shares over the ZFS pool |

Admin interfaces stay on the LAN or behind the VPN. Only Plex and Fireshare get
a public name and a real certificate, because both exist to be watched from
somewhere else.

Penpot and Foundry are public too, but never on the home IP.
They are served from the GCP node in `../mark-gcp` over a WireGuard tunnel into Caddy on `edge`.

A Quadro P400 is passed through to `plex` and `clips` for NVENC. The driver
lives on the host; the containers get a matching userspace copy and nothing
else. `scripts/pve-nvidia-prep.sh` creates the device nodes at boot, which the
driver otherwise only does on first use, too late for a container to inherit.

## Getting started

You will need a Proxmox VE host, plus `tofu`, `ansible`, `sops` and `age` on
your workstation. Point `live/prod/node/main.tf` at your host, then:

    make plan      # see what would change
    make apply     # build the containers
    make deploy    # configure them

`make help` lists the rest. Both steps are safe to re-run: applying converges
the containers, deploying converges what is inside them.

## Secrets

Secrets live in `ansible/group_vars/all/secrets.sops.yml`, encrypted with
[sops](https://getsops.io) and an [age](https://age-encryption.org) key. That
file is committed; the private key at `~/.config/sops/age/keys.txt` never is.
Ansible decrypts it automatically at run time, so no token has to be passed on
the command line.

## Going deeper

- [docs/backups.md](docs/backups.md) covers what is backed up, what is not, and
  how to restore after losing the host entirely.
- [docs/build.md](docs/build.md) covers the build box and remote compiles.
- [docs/design.md](docs/design.md) covers Penpot, first sign-in, registration,
  MCP access, upgrades, and recovery.
- [docs/foundry.md](docs/foundry.md) covers Foundry VTT, its license download, and first sign-in.
- [docs/azerothcore.md](docs/azerothcore.md) covers the WotLK server: where it is built, first deploy, rolling back, and creating accounts.
- [docs/games.md](docs/games.md) covers the game server panel: adding a server, which ports to forward, and why that one guest is a VM.
- [docs/tunnel.md](docs/tunnel.md) covers the WireGuard tunnel to GCP and how to publish another service through it.

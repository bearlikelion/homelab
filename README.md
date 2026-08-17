# server

A home Proxmox host, written down as code. OpenTofu builds the containers,
Ansible fills them, and a Makefile drives both. Nothing here is clicked into
existence in a web UI, so the whole setup can be torn down and rebuilt from
this repository.

## How it fits together

Two layers, kept apart on purpose:

- **OpenTofu** (`live/`, `modules/`) creates the LXC containers on Proxmox:
  cores, memory, disks, bind mounts, network. It owns the boxes.
- **Ansible** (`ansible/`) installs Docker and renders a Compose file into each
  one. It owns what runs inside them.

Splitting them means a service can be redeployed all day without ever touching
the container definition, and a container can be resized without redeploying
the service.

## What runs where

| Container | What it does |
|---|---|
| `media` | Radarr, Sonarr, Prowlarr, qBittorrent, Tautulli, Maintainerr |
| `plex` | Plex Media Server, the only service published to the internet |
| `edge` | Caddy reverse proxy, AdGuard Home for DNS, a dashboard, dynamic DNS |
| `vpn` | OpenVPN Access Server, the way in to everything else |
| `build` | Compiles Godot on 24 cores so a laptop does not have to |
| `social` | Postiz |
| `backup` | Backrest over restic, nightly to local disk and offsite to B2 |
| `files` | Samba shares over the ZFS pool |

Admin interfaces stay on the LAN or behind the VPN. Only Plex gets a public
name and a real certificate.

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

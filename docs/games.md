# Game servers

[Pelican](https://pelican.dev) runs on `pelican`, at `games.arneman.home`.
It is a panel over Docker: pick a game, give it memory and a port, and it pulls the right image and starts a container.
SteamCMD titles are the point of it, but the same machinery runs a Minecraft server or anything else with an egg.

Two pieces, both on the one machine:

- **Panel** is the web app and the database. It never touches a game server, it only tells the daemon what to do.
- **Wings** is the daemon. It talks to this machine's Docker socket, creates one container per server, and streams the console back to the panel.

## Why this one is a VM

Everything else on the host is an LXC container.
Wings is not, because it cannot be.
Pelican documents LXC, OpenVZ and Virtuozzo as unsupported: Wings sets cgroup, memory and swap limits on the containers it launches, and an unprivileged LXC is not allowed to hand out limits it does not own.
Ansible reaches it exactly like the containers, over SSH as root, so `make deploy` does not care about the difference.

`modules/vm` builds it from a Debian cloud image rather than an installer ISO, pinned to a dated build the way every other image here is pinned.
Nothing about the machine is clicked into existence either.

## Disks

Two, on purpose.

- 32G root on `local-zfs`, holding the panel's sqlite database and its `.env`. The nightly vzdump captures it, because losing it means rebuilding every server definition by hand.
- 300G at `/var/lib/pelican` on `fast-vm`, holding the actual server files. Marked `backup = false`, so vzdump skips it. A SteamCMD library is tens of gigabytes per title and all of it re-downloads on demand.

Add a server and its files land under `/var/lib/pelican/volumes/<uuid>`.

## Names

| Name | What answers | Why |
|---|---|---|
| `games.arneman.home` | Caddy on edge, proxying the panel | The web UI |
| `wings.arneman.home` | Caddy on edge, proxying the daemon on 8080 | The console websocket. An https page cannot open a plain-ws socket, so the daemon gets fronted too |
| `sftp.arneman.home` | the machine directly, on 2022 | SFTP is not HTTP and cannot come through a reverse proxy |

The node is registered with `scheme=https` and `proxy=1`, which is the combination that means "the panel reaches me through a proxy on 443, but I serve plain http on 8080".
Both halves call each other by those names, so both containers need Caddy's root.
The deploy installs it on the machine and mounts the finished bundle into each: wings because it is distroless and cannot build a trust store itself, the panel because PHP reads `/etc/ssl/cert.pem`, which on Alpine symlinks to the same file.
Miss either one and the symptom is a cURL error 60, "unable to get local issuer certificate", in whichever direction was left out.

## DNS, which is the part that surprises people

The router at `192.168.1.1` does not forward `arneman.home` to AdGuard.
Only AdGuard itself, on edge, answers for the internal names.

No container ever noticed, because none of them resolves an internal name: each one reaches its neighbours by address, and `getent hosts <its own name>` answers out of `/etc/hosts` rather than DNS, which makes it look like resolution works when it does not.
Wings is the first thing here that genuinely needs it, because it calls the panel back at `https://games.arneman.home`.

There is a second layer on a VM.
The cloud image runs systemd-resolved, so `/etc/resolv.conf` is the `127.0.0.53` stub, and Docker refuses a loopback resolver and quietly falls back to public DNS.
A container on this machine would therefore fail to resolve `.home` even with the host resolving it fine.

So the `common` role masks systemd-resolved on KVM guests and writes a plain `/etc/resolv.conf` with AdGuard first, which is exactly the shape every LXC already has.
Docker inherits it, and the two kinds of guest behave alike.

## First deploy

`make apply` builds the machine, `make deploy` fills it.
The role does what the web installer would have: seeds the app key, runs migrations, creates the admin account, registers the node, and writes the daemon's config out of the panel.

The admin password is generated on the box and stays there, in `/opt/pelican/admin-password`.
Sign in as `mark`.

## Adding a server

Two steps, and only the first is one-time.

1. **Allocations.** Admin > Nodes > pelican > Allocations. Add IP `192.168.1.220` with ports `27015-27100`. A server cannot be created without a free allocation to bind.
2. **Server.** Admin > Servers > New. Pick the egg, give it memory and disk out of the node's ceilings, and pick an allocation. Wings installs it and the console appears.

Ceilings are set in `group_vars`: 12G of the machine's 16G and 256G of the 300G volume, so a fully allocated node still leaves the box able to boot.

## Reaching it from outside

Nothing here is published by Caddy.
The panel and the daemon stay on `.home` names, reachable on the LAN or over the VPN, the same as every other admin interface on this host.

The game ports are the exception, and they are forwarded on the router rather than proxied: TCP and UDP `27015-27100` to `192.168.1.220`.
A game server speaks its own protocol on its own port, so there is nothing for a reverse proxy to do.
Anything outside that range is not reachable, which is why the range and the allocations should agree.

## When something is wrong

The daemon comes up whether or not it can reach the panel, so a listening port is not the same as a working node.

    ssh root@192.168.1.220 'docker logs pelican-wings | tail -50'
    ssh root@192.168.1.220 'docker logs pelican-panel | tail -50'

A node that shows red in the panel is almost always one of four things: the CA is not installed so Wings cannot verify the panel's certificate, `/etc/pelican/config.yml` is missing or stale, `wings.arneman.home` is not resolving to edge, or the machine has lost the resolv.conf above and is asking public DNS about a `.home` name.
The config is written once and never re-rendered, because Wings fills it in with its own defaults on first start; delete it and re-run the play to reissue it.

A permission error on `laravel-<date>.log` means the host side of a bind mount is owned by root.
The panel image sets `USER www-data` and chowns `/pelican-data` to it at build time, and the php-fpm pool drops to www-data whatever the container's user is, so `/opt/pelican/{data,logs,plugins}` has to be owned by uid 82 to match.
Forcing the container to root does not help: it moves the entrypoint and leaves php-fpm exactly as stuck, and the symptom names the log file rather than the database, which is also unwritable.

If the panel itself never comes up, read its log rather than its port.
Docker publishes the port as soon as the container exists, so `8000` answers even while the entrypoint is stuck, and it will sit forever waiting on a database server if `DB_CONNECTION` is anything other than the literal `sqlite`.
The panel also will not create its own sqlite file; an empty one has to exist before the first start, which is why the role touches it.

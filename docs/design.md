# Penpot

Penpot runs in the `design` LXC (230, `192.168.1.230`) and is available only
on the LAN or VPN at `https://design.arneman.home`. Caddy on `edge` terminates
HTTPS with the rack's local CA; Penpot itself listens on port 9001 over HTTP.
It is not listed in `public_services` and has no public DNS name.

The guest is deliberately ordinary: OpenTofu creates an unprivileged Debian
LXC, the common roles install Docker, and the `penpot` role renders the official
six-service Compose topology. The four Penpot images are pinned to one release;
PostgreSQL 15 and Valkey 8.1 follow the versions supported by that release.

## First deploy

Build and configure the guest with the normal workflow:

    make plan
    make apply
    make deploy

Registration starts enabled. Open `https://design.arneman.home`, create the
initial accounts, then change `penpot_registration_enabled` to `false` in
`ansible/group_vars/all/main.yml` and run `make deploy` again. Existing users
can continue to sign in; only new self-registration is removed.

There is no SMTP provider. Email verification is disabled, and invitation
tokens are written to the backend log for the small internal team:

    ssh root@192.168.1.230 \
      'docker logs penpot-backend 2>&1 | grep -i invitation'

## MCP

The Compose stack runs `penpot-mcp`, and `enable-mcp` is in `penpot_flags`, so the integration is built into the Penpot UI.
Nothing has to be installed by hand.

1. Settings, Integrations, MCP server: enable it and generate a key.
2. Point the MCP client at `https://design.arneman.home/mcp/stream?userToken=YOUR_MCP_KEY`.
3. Open a file and use the MCP button in the workspace toolbar to connect the browser side.

Step 3 is not optional.
The server has no access to a design on its own; it drives one through a plugin running in that browser tab, over `/mcp/ws`, so the tab has to stay open while the client works.

Do not add the plugin through the plugin manager by URL.
Loaded that way it has no key, and the server closes the socket with `Missing userToken parameter`.
A manual load also shows a version mismatch warning, because the bundled plugin still declares 2.17.0 while the app is 2.17.2.
The toolbar path keeps that window hidden and is unaffected.

There is no port 4400 on this host.
That port belongs to the single-user `penpot-mcp` package run on a workstation, which serves its own copy of the plugin files.
Here the frontend serves the bundled plugin at `/plugins/mcp/` and proxies the server, all on 443.

The client machine must trust `caddy-root-ca.crt`, just like any other internal service.
Treat the MCP key as a password.

## Data, backups, and recovery

PostgreSQL data and uploaded assets live in the `penpot_postgres_v15` and
`penpot_assets` Docker volumes. Both are inside the 100G guest root filesystem,
so the nightly vzdump archive captures them and the generated `/opt/penpot/.env`
together. Do not move either volume to a bind mount without adding a separate
backup for it; Proxmox excludes bind mounts from vzdump.

For a full recovery, restore guest 230 from its vzdump archive. Rebuilding it
with OpenTofu and Ansible creates a clean Penpot installation but cannot recover
the designs.

## Upgrades and diagnostics

Upgrade all four `penpotapp/*` variables to the same release in
`ansible/group_vars/all/main.yml`, review the upstream release notes, and run
`make deploy`. Database migrations run as the backend starts.

Useful checks from the guest:

    cd /opt/penpot
    docker compose ps
    docker compose logs -f

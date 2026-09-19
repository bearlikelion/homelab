# vMaNGOS

A private vanilla 1.12.1 server (client build 5875) on `vmangos`.
Container 251, `vmangos`, 4 cores and 4G, at `192.168.1.251`.
LAN only, like `azcore`.

## Where it is built

On the workstation, not on `build`.
The checkout at `/mnt/Storage/mWoW/Vanilla/vmangos` carries local patches and has no Forgejo remote, so there is nothing for the runner to pick up.
`/mnt/Storage/mWoW/Vanilla/server` is the Compose project that builds the `vmangos:5875` image from it.
It also holds the extracted client data and the working configs the role seeds from.

    cd /mnt/Storage/mWoW/Vanilla/server && docker compose build

The role compares the image ID on the workstation with the one on the box, and streams it across with `docker save | docker load` when they differ.

## How it runs

| Container | Does |
|---|---|
| `vmangos-db` | MariaDB 11.4, data in `/opt/vmangos/mysql` on the rootfs |
| `vmangos-realmd` | Login, port 3724 |
| `vmangos-mangosd` | The world, port 8085 |

`data/` holds dbc and maps only, no vmaps or mmaps, so those stay off in `mangosd.conf`.
It is rsynced from the workstation on every deploy.

Configuration is `/opt/vmangos/etc/<app>.conf`, seeded from the workstation's copies on the first deploy and never overwritten after.
The exception is the database lines, which the role rewrites every run.
The password is `vmangos_db_password` in sops.

## First deploy

MariaDB loads `db-init/` only into an empty data directory, so the first deploy needs a dump to load.
Take it from the workstation's stack with the servers stopped, so characters are saved first:

    cd /mnt/Storage/mWoW/Vanilla/server
    docker stop -t 60 vmangos-mangosd vmangos-realmd
    docker exec -e MYSQL_PWD=<root password from .env> vmangos-db \
      mariadb-dump --user=root --databases realmd characters mangos logs | gzip > $HOME/vmangos-seed.sql.gz

Then:

    make plan && make apply
    cd ansible && ansible-playbook site.yml --limit vmangos -e vmangos_db_seed=$HOME/vmangos-seed.sql.gz

The play fails early if there is no database and no seed.
Its last step points the realm at `192.168.1.251`.

## Deploying a new build

    cd /mnt/Storage/mWoW/Vanilla/server && docker compose build
    cd ~/Source/server/ansible && ansible-playbook site.yml --limit vmangos

## The client

`realmlist.wtf` in the client folder:

    set realmlist 192.168.1.251

## Accounts

    ssh root@192.168.1.251
    docker attach vmangos-mangosd
    account create <name> <password>
    account set gmlevel <name> 6

Detach with Ctrl-p Ctrl-q.

## When something is wrong

    ssh root@192.168.1.251 'docker logs vmangos-db | tail -50'
    ssh root@192.168.1.251 'docker logs vmangos-mangosd | tail -50'

Server logs are also written to `/opt/vmangos/logs`.

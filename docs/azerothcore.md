# AzerothCore

A private WotLK server on `azcore`, for the desktop client to connect to.
Container 250, `azcore`, 4 cores and 8G, at `192.168.1.250`.
LAN only: nothing is forwarded on the router and there is no internal name.

## Where it is built

Nothing compiles on `azcore`.
The `mark/azerothcore` repository carries `.forgejo/workflows/build.yml`, which the runner on `build` picks up on every push to `main`.
The job runs in `ubuntu:24.04`, the same base as upstream's Dockerfile, because AzerothCore needs Boost 1.78 and Debian 12 ships 1.74.

It writes to the build pool, never to Forgejo:

| Path on build | Holds | Written |
|---|---|---|
| `/build/artifacts/azerothcore/core/<sha>` | `bin/`, `etc/*.conf.dist`, `data/sql` | Every push |
| `/build/artifacts/azerothcore/data/<sha>` | `dbc`, `maps`, `Cameras`, `vmaps`, `mmaps` | Only when run by hand with `extract_data` ticked |
| `core/latest`, `data/latest` | Symlinks to the newest of each | With each of the above |

Each sha is staged under a dot name and renamed into place, so a half-written build is never visible under its real name.
Map data takes hours, mostly `mmaps_generator`, and only changes when the client or the extractors do, which is why it is not part of the push build.

The extractors read the client from `/build/data/wotlk-client/Data`.
The `build` role pushes it there from `wotlk_client_source` on the workstation, and skips the push on a control node that does not have it.

`build_runner_valid_volumes` lists every path a job may mount.
A workflow that mounts anything else fails before its first step.

## How it runs

Four containers from one Compose file, a trimmed copy of upstream's:

| Container | Does |
|---|---|
| `ac-database` | MySQL 8.4, data in `/opt/azerothcore/mysql` on the rootfs |
| `ac-db-import` | Creates and updates the three databases, then exits |
| `ac-authserver` | Login, port 3724 |
| `ac-worldserver` | The world, port 8085 |

The three servers share one image, `azerothcore/runtime`, which is only upstream's runtime libraries.
Their binaries, SQL and map data are bind mounted by sha from `/srv/azerothcore`, a read-only mount of `/fast/build/artifacts/azerothcore` on the host.
The database is the one thing here that cannot be regenerated, and it is in the rootfs so the nightly vzdump holds it.

Configuration is `/opt/azerothcore/etc/<app>.conf`, seeded from the build's `.conf.dist` on the first deploy and never overwritten after.
Database connection strings come from environment variables in the Compose file, which AzerothCore prefers over the file.
The password is `azerothcore_db_password` in sops.

## First deploy

Order matters, because each step reads what the one before it wrote.

    cd ansible && ansible-playbook site.yml --limit build     # runner volumes, client push
    git -C <azerothcore checkout> push                        # first core build

Then run the workflow by hand from the repository's Actions tab with `extract_data` ticked, and wait for it.

    make plan && make apply                                   # container 250
    cd ansible && ansible-playbook site.yml --limit azcore

The play fails early, and says which, if the mount, the core build or the map data is missing.
Its last step rewrites the realm address from `127.0.0.1` to the container's own, retrying while `ac-db-import` is still filling a fresh database.

## Deploying a new build

Push to `main`, wait for the run, then:

    cd ansible && ansible-playbook site.yml --limit azcore

The play resolves `latest` to a sha and writes that sha into the Compose file.
A later CI run therefore never changes what a running server has open.

To roll back, name an older build:

    ansible-playbook site.yml --limit azcore -e azerothcore_core_build=<sha>

`azerothcore_data_build` does the same for map data.
Old builds are never deleted yet; each is about a gigabyte on a 2T pool.

## Accounts

The server console is the worldserver's terminal.

    ssh root@192.168.1.250
    docker attach ac-worldserver
    account create <name> <password>
    account set gmlevel <name> 3 -1

Detach with Ctrl-p Ctrl-q.
Ctrl-c shuts the world down, and Docker starts it straight back up.

## When something is wrong

    ssh root@192.168.1.250 'docker logs ac-db-import | tail -50'
    ssh root@192.168.1.250 'docker logs ac-worldserver | tail -50'

The worldserver waits for `ac-db-import` to exit cleanly, so a server that never starts is usually a failed import.
Server logs are also written to `/opt/azerothcore/logs`.

A client that logs in and then hangs on the realm list is being sent to the wrong address.
Check `SELECT address FROM acore_auth.realmlist` in `ac-database`; the play sets it on every run.

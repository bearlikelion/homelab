# Code

Forgejo, so the git repositories on this network stop living only on a laptop and in someone else's cloud.
Container 210, `code`, 2 cores and 4G.
The Actions runner that executes its workflows lives on `build`, not here.

## Names

| Name | Serves | Path |
|---|---|---|
| `code.arneman.home` | The web UI and HTTPS clones | AdGuard to Caddy on `edge`, then to the container |
| `git.arneman.home` | Git over SSH, port 2222 | AdGuard straight to the container |

Two names because git over SSH is not HTTP.
Caddy only proxies HTTP, so an SSH clone has to reach the container itself, and `internal_dns_overrides` in `group_vars` is what makes that one name skip the proxy.

Clone URLs look like this:

    git clone https://code.arneman.home/mark/repo.git
    git clone ssh://git@git.arneman.home:2222/mark/repo.git

HTTPS clones need the Caddy root installed, the same certificate every other `.home` name uses.
`http://ca.arneman.home/caddy-root-ca.crt` serves it.

## Storage

Repositories live in the container rootfs at `/opt/code/data`, not on a bind mount.
That is the opposite of every other container here and it is deliberate: vzdump skips bind mounts, and git history is exactly what the nightly archive should be holding.
The 32G root disk is the ceiling on the whole instance, so grow it before the repositories get close.

The database is SQLite, in the same directory.
A single-user instance with one runner never reaches the write concurrency where Postgres would earn its second container.

## First deploy

    make apply                      # build container 210
    make deploy                     # Forgejo, then the runner on build

The role creates the admin account from the CLI rather than leaving the first-run web installer in the way.
Its password is generated on the box and stays there:

    ssh root@192.168.1.210 cat /opt/code/admin-password

Sign in as `mark`, then add an SSH public key under Settings > SSH Keys before the first push.

## The runner

`build_runner` registers a Forgejo Actions runner on the build box using the offline flow.
A 40 character hex secret is generated on `build`, handed to Forgejo with `forgejo-cli actions register`, and Forgejo answers with the UUID that pairs with it.
Both ends then hold the same credential, so a re-deploy converges instead of needing a fresh single-use token every time.
The secret is kept at `/build/ci/secret`; deleting it registers a second runner and orphans the first.

Jobs run in containers on the build box's Docker daemon, which is why Forgejo is not on that box: a runner that can start containers is root there.
The toolchain installed by the `build` role is for the ssh-driven builds in [build.md](build.md) and is not visible to a job, which sees only its own image.

Two labels, both `node:22-bookworm`:

| Label | For |
|---|---|
| `ubuntu-latest` | Workflows lifted from GitHub, so `runs-on` needs no rewriting |
| `docker` | The same thing, named for what it actually is |

Node is not incidental.
`checkout`, `cache` and `upload-artifact` are all Node actions, so a job image without a Node runtime cannot run a workflow at all.

Workflows go in `.forgejo/workflows/` in a repository:

```yaml
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: make
```

## Certificates

Caddy signs `code.arneman.home` with its own root, so the runner and every job container have to trust it or the first poll fails on certificate verification.
The role installs `caddy-root-ca.crt` from the repository root into the build box's trust store, mounts `/etc/ssl/certs` into the runner, and passes the same mount to job containers through `container.options`.
The edge role refreshes that file on every deploy, so deploy `edge` before `build` on a fresh host.

The build box resolves DNS through the router rather than AdGuard, so `code.arneman.home` is pinned in `/etc/hosts` and in the job containers with `--add-host`.
Harmless if DNS already answers for it.

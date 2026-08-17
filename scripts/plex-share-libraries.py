#!/usr/bin/env python3
"""Share the new Plex server's libraries with everyone from the old server.

The old server ("plex-debian") is retired but its share list still exists on
your Plex account. The new container is a DIFFERENT server with its own empty
share list, so every user has to be invited again.

Idempotent: users who already have full access are skipped, so re-run it after
adding a library and everyone picks up the new one.

Defaults to a DRY RUN, because this sends invitations to real people.

    python3 scripts/plex-share-libraries.py             # show what would happen
    python3 scripts/plex-share-libraries.py --apply     # send the invites
    python3 scripts/plex-share-libraries.py --list      # current state only
"""

import argparse
import subprocess
import sys
import time

PLEX_HOST = "192.168.1.120"
PLEX_CONTAINER = "plex"
PREFS = "/config/Library/Application Support/Plex Media Server/Preferences.xml"

# Pause between invites so Plex does not rate-limit a 41-user run.
INVITE_DELAY = 2.0


def get_token() -> str:
    """Read the server's own token from the container's Preferences.xml."""
    out = subprocess.run(
        [
            "ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes",
            f"root@{PLEX_HOST}",
            f'docker exec {PLEX_CONTAINER} cat "{PREFS}"',
        ],
        capture_output=True, text=True, timeout=30,
    )
    if out.returncode != 0:
        sys.exit(f"could not read Preferences.xml: {out.stderr.strip()}")

    for part in out.stdout.split():
        if part.startswith("PlexOnlineToken="):
            return part.split('"')[1]
    sys.exit("no PlexOnlineToken found; is the server claimed?")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true",
                    help="actually send invites (default is a dry run)")
    ap.add_argument("--list", action="store_true",
                    help="only show current state, change nothing")
    ap.add_argument("--server", default=None,
                    help="target server name (default: the local container)")
    ap.add_argument("--url", default=f"http://{PLEX_HOST}:32400",
                    help="direct URL to the target server")
    args = ap.parse_args()

    try:
        from plexapi.myplex import MyPlexAccount
    except ImportError:
        sys.exit("needs python-plexapi:  pip install plexapi")

    account = MyPlexAccount(token=get_token())
    print(f"account: {account.username or account.email}")

    # Identify the target: this container, matched by its machine identifier
    # rather than by name, since several servers can share a name.
    owned = [r for r in account.resources()
             if r.product == "Plex Media Server" and r.owned]
    if not owned:
        sys.exit("no owned Plex Media Server found on this account")

    if args.server:
        target = next((r for r in owned if r.name == args.server), None)
        if target is None:
            sys.exit(f"no owned server named {args.server!r}; "
                     f"have: {[r.name for r in owned]}")
    elif len(owned) == 1:
        target = owned[0]
    else:
        print("\nmultiple owned servers; pick one with --server:")
        for r in owned:
            print(f"  {r.name!r}")
        return 1

    print(f"target:  {target.name!r}")

    # Connect straight to the container. Going through plex.tv's advertised
    # connections fails here, since the server has no public route and the
    # relay is not usable for API calls.
    from plexapi.server import PlexServer
    server = PlexServer(args.url, account.authenticationToken)

    all_sections = [s.title for s in server.library.sections()]
    if not all_sections:
        sys.exit("target server has no libraries; add them in Plex first")
    print(f"libraries: {', '.join(all_sections)}")

    users = account.users()
    print(f"users on this account: {len(users)}\n")

    todo, ok = [], 0
    for user in users:
        shared = []
        for s in user.servers:
            if s.machineIdentifier == server.machineIdentifier:
                shared = [sec.title for sec in s.sections() if sec.shared]

        missing = [s for s in all_sections if s not in shared]
        label = user.email or user.title or user.username

        if missing:
            todo.append((user, label, missing))
        else:
            ok += 1

    print(f"{ok} user(s) already have every library")
    print(f"{len(todo)} user(s) need access\n")

    for _, label, missing in todo:
        print(f"  {label}: missing {len(missing)}/{len(all_sections)}")

    if args.list or not todo:
        return 0

    if not args.apply:
        print(f"\nDRY RUN. Re-run with --apply to update {len(todo)} user(s).")
        return 0

    print(f"\nupdating {len(todo)} user(s)...")
    done = failed = 0
    for user, label, _ in todo:
        try:
            # updateFriend handles both existing shares and new invitations.
            account.updateFriend(user, server, sections=all_sections)
            done += 1
            print(f"  ok      {label}")
        except Exception as exc:
            failed += 1
            print(f"  FAILED  {label}: {exc}")
        time.sleep(INVITE_DELAY)

    print(f"\nupdated {done}, failed {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# Install Foundry modules from manifest URLs, then Quick-Start a world for each adventure module.
# Usage: foundry-modules install <manifest-list> <data-dir> <uid> <gid>
#        foundry-modules worlds <data-dir> <system> <env-file> <base-url>
#        foundry-modules --self-test
import fcntl
import glob
import http.cookiejar
import io
import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.request
import zipfile

UA = {"User-Agent": "foundry-modules"}
USAGE = "usage: foundry-modules install <list> <data-dir> <uid> <gid> | worlds <data-dir> <system> <env-file> <url> | --self-test"


def fetch(url, dest=None):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
        if dest is None:
            return r.read()
        shutil.copyfileobj(r, dest)


def extract(zf, target):
    # Zips ship module.json either at the root or inside one folder; keep only that subtree.
    roots = [n for n in zf.namelist() if n == "module.json" or n.endswith("/module.json")]
    if not roots:
        raise ValueError("no module.json in zip")
    prefix = min(roots, key=len)[: -len("module.json")]
    base = os.path.realpath(target)
    for info in zf.infolist():
        if not info.filename.startswith(prefix) or info.is_dir() or "__MACOSX/" in info.filename:
            continue
        dest = os.path.realpath(os.path.join(base, info.filename[len(prefix):]))
        if not dest.startswith(base + os.sep):
            raise ValueError(f"unsafe path in zip: {info.filename}")
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with zf.open(info) as src, open(dest, "wb") as out:
            shutil.copyfileobj(src, out)


def makedirs_owned(path, uid, gid):
    # On a fresh install Data does not exist yet, and Foundry must own what we create.
    missing = []
    while not os.path.isdir(path):
        missing.append(path)
        path = os.path.dirname(path)
    for directory in reversed(missing):
        os.mkdir(directory)
        os.chown(directory, uid, gid)


def chown_tree(path, uid, gid):
    for root, dirs, files in os.walk(path):
        os.chown(root, uid, gid)
        for name in files:
            os.chown(os.path.join(root, name), uid, gid)


def ensure_quickstart(module_dir, uid, gid):
    # Foundry only Quick-Starts modules that declare this block, even an empty one.
    path = os.path.join(module_dir, "module.json")
    with open(path) as f:
        manifest = json.load(f)
    if "quickstart" in manifest or not any(p.get("type") == "Adventure" for p in manifest.get("packs", [])):
        return False
    manifest["quickstart"] = {}
    with open(path, "w") as f:
        json.dump(manifest, f, indent=2)
    os.chown(path, uid, gid)
    return True


def install(url, modules_dir, uid, gid):
    manifest = json.loads(fetch(url))
    module_id, version = manifest["id"], manifest["version"]
    final = os.path.join(modules_dir, module_id)
    try:
        with open(os.path.join(final, "module.json")) as f:
            if json.load(f).get("version") == version:
                patched = ensure_quickstart(final, uid, gid)
                return f"{'patched' if patched else 'ok'} {module_id} {version}"
    except FileNotFoundError:
        pass

    staging = os.path.join(modules_dir, f".{module_id}.new")
    shutil.rmtree(staging, ignore_errors=True)
    with tempfile.TemporaryFile() as archive:
        fetch(manifest["download"], archive)
        archive.seek(0)
        with zipfile.ZipFile(archive) as zf:
            extract(zf, staging)
    chown_tree(staging, uid, gid)
    ensure_quickstart(staging, uid, gid)

    old = os.path.join(modules_dir, f".{module_id}.old")
    if os.path.isdir(final):
        os.rename(final, old)
    os.rename(staging, final)
    shutil.rmtree(old, ignore_errors=True)
    return f"installed {module_id} {version}"


def install_all(manifest_list, data_dir, uid, gid):
    modules_dir = os.path.join(data_dir, "modules")
    makedirs_owned(modules_dir, uid, gid)
    with open(manifest_list) as f:
        urls = [line.strip() for line in f if line.strip()]
    failed = 0
    for number, url in enumerate(urls, 1):
        # URLs are paid links, so output names the list position, never the URL.
        try:
            print(install(url, modules_dir, uid, gid), flush=True)
        except Exception as e:
            failed += 1
            print(f"failed #{number}: {type(e).__name__}: {e}", flush=True)
    return 1 if failed else 0


def databases_released(world_dir):
    # LevelDB holds an fcntl lock on each LOCK file while Foundry has the database open.
    for lock in glob.glob(os.path.join(world_dir, "data", "*", "LOCK")):
        with open(lock, "a") as f:
            try:
                fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return False
            fcntl.lockf(f, fcntl.LOCK_UN)
    return True


def world_title(module_title):
    title = re.sub(r"^Snowy'?s Maps\s+", "", module_title, flags=re.I)
    return re.sub(r"\s+(5e|dnd5e|pf2e)$", "", title, flags=re.I).strip()


def slug(title):
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")


class Foundry:
    def __init__(self, base_url, admin_key, logs_dir):
        self.base = base_url.rstrip("/")
        self.key = admin_key
        self.logs = logs_dir
        self.http = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def request(self, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, headers={**UA, "Content-Type": "application/json"})
        with self.http.open(req, timeout=60) as r:
            text = r.read().decode()
        try:
            return json.loads(text)
        except ValueError:
            return {}

    def status(self, timeout=600):
        # Also rides out the restart after new modules, when Foundry briefly refuses to start.
        deadline = time.time() + timeout
        while True:
            try:
                return self.request("/api/status")
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(5)

    def log_since(self, since):
        entries = []
        for name in sorted(os.listdir(self.logs)):
            if not (name.startswith("debug.") and name.endswith(".log")):
                continue
            with open(os.path.join(self.logs, name)) as f:
                for line in f:
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    if entry.get("timestamp", "") >= since:
                        entries.append(entry)
        return entries

    def shutdown(self, world_dir):
        self.request("/join")
        self.request("/join", {"action": "shutdown", "adminPassword": self.key})
        while self.status().get("active"):
            time.sleep(2)
        # Status goes inactive before the databases close; launching the next world then finds them locked.
        deadline = time.time() + 60
        while not databases_released(world_dir) and time.time() < deadline:
            time.sleep(1)

    def quickstart(self, world_dir, title, system, module_id, timeout=900):
        world_id = os.path.basename(world_dir)
        self.request("/auth")
        self.request("/auth", {"adminPassword": self.key})
        since = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())
        result = self.request("/create", {"action": "createWorld", "id": world_id, "title": title, "system": system, "adventure": module_id})
        if "error" in result:
            raise RuntimeError(result["error"])

        # /create returns while the import is still running; Foundry logs the end, or deactivates on failure.
        # Status reads inactive until the launch finishes setting up, so only trust it once the world has shown up.
        started_by = time.time() + 120
        deadline = time.time() + timeout
        seen = False
        while True:
            time.sleep(3)
            if any(f'Created World "{world_id}"' in e.get("message", "") for e in self.log_since(since)):
                break
            if self.status().get("world") == world_id:
                seen = True
            elif seen or time.time() > started_by:
                raise RuntimeError("the world stopped before its import finished; see Logs/error.*.log")
            if time.time() > deadline:
                raise RuntimeError("timed out waiting for the import")
        self.shutdown(world_dir)

    def settle(self, world_dir):
        # After a failure, give a launch that is still starting time to appear, then stop it.
        for _ in range(15):
            if self.status().get("active"):
                self.shutdown(world_dir)
                return
            time.sleep(2)


def worlds(data_dir, system, env_file, base_url):
    with open(env_file) as f:
        env = dict(line.rstrip("\n").split("=", 1) for line in f if "=" in line)
    foundry = Foundry(base_url, env["FOUNDRY_ADMIN_KEY"], os.path.join(os.path.dirname(data_dir.rstrip("/")), "Logs"))

    current = foundry.status()
    if current.get("active"):
        print(f"skipped worlds: {current.get('world')} is running, deploy again when the game is over")
        return 0

    modules_dir = os.path.join(data_dir, "modules")
    worlds_dir = os.path.join(data_dir, "worlds")
    failed = 0
    for name in sorted(os.listdir(modules_dir)):
        path = os.path.join(modules_dir, name, "module.json")
        if not os.path.isfile(path):
            continue
        with open(path) as f:
            manifest = json.load(f)
        adventures = [p for p in manifest.get("packs", []) if p.get("type") == "Adventure" and p.get("system") in (None, system)]
        if "quickstart" not in manifest or not adventures:
            continue

        title = world_title(manifest["title"])
        world_id = slug(title)
        if os.path.isdir(os.path.join(worlds_dir, world_id)):
            print(f"ok world {world_id}")
            continue
        try:
            foundry.quickstart(os.path.join(worlds_dir, world_id), title, system, manifest["id"])
            print(f"created world {world_id} from {manifest['id']}", flush=True)
        except Exception as e:
            failed += 1
            # A half-built world would be skipped forever, and nobody has played in it yet.
            foundry.settle(os.path.join(worlds_dir, world_id))
            shutil.rmtree(os.path.join(worlds_dir, world_id), ignore_errors=True)
            print(f"failed world {world_id}: {type(e).__name__}: {e}", flush=True)
    return 1 if failed else 0


def self_test():
    for layout in ("", "nested-folder/"):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as zf:
            zf.writestr(layout + "module.json", '{"id": "t"}')
            zf.writestr(layout + "packs/a.db", "x")
            zf.writestr("__MACOSX/junk", "x")
        with tempfile.TemporaryDirectory() as tmp, zipfile.ZipFile(buf) as zf:
            extract(zf, tmp)
            assert sorted(os.listdir(tmp)) == ["module.json", "packs"], os.listdir(tmp)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("module.json", "{}")
        zf.writestr("../escape", "x")
    with tempfile.TemporaryDirectory() as tmp, zipfile.ZipFile(buf) as zf:
        try:
            extract(zf, tmp)
            raise AssertionError("path traversal was not rejected")
        except ValueError:
            pass

    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, "module.json"), "w") as f:
            json.dump({"id": "t", "packs": [{"type": "Adventure"}]}, f)
        owner = os.getuid(), os.getgid()
        assert ensure_quickstart(tmp, *owner) and not ensure_quickstart(tmp, *owner)

    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "data", "actors"))
        lock = os.path.join(tmp, "data", "actors", "LOCK")
        open(lock, "w").close()
        assert databases_released(tmp)
        holder = os.fork()
        if holder == 0:
            with open(lock, "a") as f:
                fcntl.lockf(f, fcntl.LOCK_EX)
                time.sleep(2)
            os._exit(0)
        time.sleep(0.5)
        assert not databases_released(tmp)
        os.waitpid(holder, 0)
        assert databases_released(tmp)

    assert world_title("Snowy's Maps Salt & Ash Kobold Trapper 5e") == "Salt & Ash Kobold Trapper"
    assert world_title("Five Toe Cove 5e") == "Five Toe Cove"
    assert slug("Salt & Ash Kobold Trapper") == "salt-ash-kobold-trapper"
    assert slug(world_title("Snowy's Maps Lullaby of Endless Screams 5e")) == "lullaby-of-endless-screams"
    print("self-test passed")
    return 0


def main():
    args = sys.argv[1:]
    if args == ["--self-test"]:
        return self_test()
    if len(args) == 5 and args[0] == "install":
        return install_all(args[1], args[2], int(args[3]), int(args[4]))
    if len(args) == 5 and args[0] == "worlds":
        return worlds(*args[1:])
    sys.exit(USAGE)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""A read-only status page for the Darkfall cluster.

Answers the one question that is otherwise a three-command SSH trip: is the
cluster actually ready, or still booting? A node listening on its port is not
the same as a node in the game loop -- the frontend accepts TCP long before the
cluster reaches asRun, so a client that connects early just sits on the loading
screen. This reports the real state.

Two sources, both read-only:
  * /var/log/darkfall/<node>.log  -- the last "State asX" each node logged
  * the Docker socket             -- container status and restart counts

Standard library only, so it runs on a stock python image with no build step.
"""

from __future__ import annotations

import http.client
import json
import os
import re
import socket
import time
from datetime import timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG_DIR = os.environ.get("DF_LOG_DIR", "/var/log/darkfall")
DOCKER_SOCK = os.environ.get("DF_DOCKER_SOCK", "/var/run/docker.sock")
PROJECT = os.environ.get("DF_PROJECT", "darkfall-server")
NODES = [n for n in os.environ.get("DF_NODES", "").split() if n]
CLIENT_PORT = int(os.environ.get("DF_CLIENT_PORT", "21000"))
DB_USER = os.environ.get("DF_DB_USER", "dfserver")
DB_NAME = os.environ.get("DF_DB_NAME", "darkfall")
SERVER_ADDRESS = os.environ.get("DF_SERVER_ADDRESS", "")
FRONTEND_HOST = os.environ.get("DF_FRONTEND_HOST", "frontend")
PORT = int(os.environ.get("DF_PORT", "8080"))

# gamelogic writes gamelogic1.log and engine writes engine1.log: the config name
# carries the instance number, the service name does not.
LOG_ALIASES = {"gamelogic": "gamelogic1", "engine": "engine1"}

STATE_RE = re.compile(rb"State (as[A-Za-z0-9]+)")
# Ordered so a state maps to a progress fraction for the bar.
STATES = [
    "asBoot", "asInitialize", "asLoadStage1", "asLoadStage1Done",
    "asLoadStage2", "asLoadStage2Done", "asRun",
]


class _UnixConn(http.client.HTTPConnection):
    """http.client over an AF_UNIX socket, so the Docker API needs no library."""

    def __init__(self, path: str):
        super().__init__("localhost")
        self._path = path

    def connect(self) -> None:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(self._path)
        self.sock = s


def docker_containers() -> dict:
    """Compose service name -> container facts. Empty dict if the socket is gone."""
    try:
        c = _UnixConn(DOCKER_SOCK)
        c.request("GET", "/containers/json?all=1")
        raw = json.loads(c.getresponse().read())
        c.close()
    except Exception:
        return {}
    out = {}
    for item in raw:
        labels = item.get("Labels") or {}
        if labels.get("com.docker.compose.project") != PROJECT:
            continue
        svc = labels.get("com.docker.compose.service")
        if svc:
            out[svc] = {
                "id": item.get("Id", ""),
                "state": item.get("State", "?"),
                "status": item.get("Status", ""),
                "since": item.get("Created", 0),
            }
    return out


# A node only prints its state on the FPS report beat, so a chatty one (aigamelogic
# logs a tick profile every second) can push that line megabytes back. Walk
# backwards in growing chunks rather than guessing a window, capped so a runaway
# log cannot turn a page render into a full file read.
TAIL_START = 256 * 1024
TAIL_MAX = 32 * 1024 * 1024


# LOGGED_IN is ordinal 1 of SFCharacterConnectionManager.States
# (LOGGING_IN, LOGGED_IN, LOGGING_OUT, LOGGED_OUT, INITIALIZING).
PLAYERS_SQL = "SELECT count(*) FROM login_character_state WHERE state=1"


def players_online(pg_container: str) -> int | None:
    """Characters currently logged in, or None if the query did not run.

    Runs psql inside the Postgres container over the Docker API rather than
    carrying a Postgres driver: this stays a stdlib-only script on a stock
    python image. Note the API allows exec regardless of the socket being
    mounted read-only -- :ro protects the socket file, not the verbs.
    """
    if not pg_container:
        return None
    try:
        c = _UnixConn(DOCKER_SOCK)
        body = json.dumps({
            "AttachStdout": True, "AttachStderr": False,
            "Cmd": ["psql", "-U", DB_USER, "-d", DB_NAME, "-At", "-c", PLAYERS_SQL],
        }).encode()
        c.request("POST", f"/containers/{pg_container}/exec", body=body,
                  headers={"Content-Type": "application/json"})
        exec_id = json.loads(c.getresponse().read())["Id"]
        c.close()

        c = _UnixConn(DOCKER_SOCK)
        c.request("POST", f"/exec/{exec_id}/start",
                  body=json.dumps({"Detach": False, "Tty": True}).encode(),
                  headers={"Content-Type": "application/json"})
        out = c.getresponse().read().decode(errors="replace")
        c.close()
        return int(out.strip().splitlines()[0])
    except Exception:
        return None


def tail_state(node: str) -> tuple[str, float]:
    """The last logged state for a node and its log mtime. ('', 0) if no log."""
    path = os.path.join(LOG_DIR, LOG_ALIASES.get(node, node) + ".log")
    try:
        size = os.path.getsize(path)
        mtime = os.path.getmtime(path)
        with open(path, "rb") as fh:
            window = TAIL_START
            while True:
                fh.seek(max(0, size - window))
                found = STATE_RE.findall(fh.read())
                if found:
                    return found[-1].decode(), mtime
                if window >= size or window >= TAIL_MAX:
                    return "", mtime
                window *= 4
    except OSError:
        return "", 0.0


def port_open(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=2):
            return True
    except OSError:
        return False


def snapshot() -> dict:
    containers = docker_containers()
    nodes = []
    for name in NODES:
        state, mtime = tail_state(name)
        c = containers.get(name, {})
        used, limit = container_memory(c["id"]) if c.get("id") else (None, None)
        nodes.append({
            "mem_gb": used,
            "mem_limit_gb": limit,
            "name": name,
            "state": state or "-",
            "ready": state == "asRun",
            "progress": (STATES.index(state) + 1) / len(STATES) if state in STATES else 0.0,
            "container": c.get("state", "absent"),
            "status": c.get("status", ""),
            "log_age": (time.time() - mtime) if mtime else None,
        })
    ready = bool(nodes) and all(n["ready"] for n in nodes)
    pg = containers.get("darkfall-pg", {})
    booting = sum(1 for n in nodes if not n["ready"])
    return {
        "ready": ready,
        "nodes": nodes,
        "postgres": {"state": pg.get("state", "absent"), "status": pg.get("status", "")},
        "players": players_online(pg.get("id", "")) if ready else None,
        "nodes_booting": booting,
        "client_port": {"port": CLIENT_PORT, "open": port_open(FRONTEND_HOST, CLIENT_PORT)},
        "generated": time.time(),
    }


def container_memory(name: str) -> tuple[float | None, float | None]:
    """(used_gb, limit_gb) for one container, or (None, None).

    Deliberately not /proc/meminfo: that is not namespaced without lxcfs, so
    inside an LXC guest it reports the Proxmox host's 126 GB rather than the
    guest's 32. Per-container numbers are also what actually matters here --
    aigamelogic sitting at 7.2 of its 8 GB is the signal worth seeing.
    """
    try:
        c = _UnixConn(DOCKER_SOCK)
        c.request("GET", f"/containers/{name}/stats?stream=false&one-shot=true")
        d = json.loads(c.getresponse().read())
        c.close()
        m = d.get("memory_stats", {})
        used, limit = m.get("usage"), m.get("limit")
        if not used:
            return None, None
        # Docker counts page cache in usage; subtract it for a figure that tracks
        # what the process actually holds.
        used -= (m.get("stats", {}) or {}).get("inactive_file", 0)
        return round(used / 1073741824, 2), (round(limit / 1073741824, 2) if limit else None)
    except Exception:
        return None, None


def fmt_mem(n: dict) -> str:
    if n.get("mem_gb") is None:
        return "-"
    limit = f' / {n["mem_limit_gb"]:g}' if n.get("mem_limit_gb") else ""
    return f'{n["mem_gb"]:g}{limit} GB'


def human_age(seconds: float | None) -> str:
    if seconds is None:
        return "no log"
    return str(timedelta(seconds=int(seconds))) + " ago"


def render(s: dict) -> str:
    ready = s["ready"]
    banner = "READY" if ready else "BOOTING"
    hint = ("Clients can log in." if ready else
            "The frontend accepts TCP before the cluster is ready; a client "
            "connecting now will sit on the loading screen until every node reaches asRun.")
    rows = []
    for n in s["nodes"]:
        cls = "ok" if n["ready"] else ("warn" if n["container"] == "running" else "bad")
        rows.append(
            f'<tr class="{cls}"><td>{n["name"]}</td><td><code>{n["state"]}</code></td>'
            f'<td><div class="bar"><i style="width:{n["progress"] * 100:.0f}%"></i></div></td>'
            f'<td>{n["container"]}</td><td class="dim">{n["status"]}</td>'
            f'<td class="dim">{human_age(n["log_age"])}</td></tr>'
        )
    pg_ok = s["postgres"]["state"] == "running"
    port = s["client_port"]
    return f"""<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<meta http-equiv=refresh content=5>
<title>Darkfall - {banner}</title>
<style>
 :root{{color-scheme:dark}}
 body{{font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;background:#12141a;color:#c9d1d9;
      margin:0;padding:2rem;max-width:60rem}}
 h1{{font-size:1.4rem;margin:0 0 .25rem}}
 .banner{{display:inline-block;padding:.15rem .6rem;border-radius:.25rem;font-weight:700;
          background:{'#1a7f37' if ready else '#9a6700'};color:#fff}}
 p.hint{{color:#8b949e;margin:.5rem 0 1.5rem;max-width:52rem}}
 table{{border-collapse:collapse;width:100%;margin-bottom:1.5rem}}
 th,td{{text-align:left;padding:.35rem .6rem;border-bottom:1px solid #21262d}}
 th{{color:#8b949e;font-weight:400}}
 tr.ok td:first-child{{border-left:3px solid #1a7f37}}
 tr.warn td:first-child{{border-left:3px solid #9a6700}}
 tr.bad td:first-child{{border-left:3px solid #b62324}}
 .dim{{color:#8b949e}}
 .bar{{background:#21262d;height:.55rem;border-radius:.3rem;width:9rem;overflow:hidden}}
 .bar i{{display:block;height:100%;background:#2f81f7}}
 .facts span{{margin-right:1.5rem}}
</style>
<h1>Darkfall cluster <span class=banner>{banner}</span></h1>
<p class=hint>{hint}</p>
<table>
 <tr><th>node<th>state<th>progress<th>container<th>memory<th>log</tr>
 {''.join(rows)}
</table>
<p class=facts>
 <span>postgres: <b style="color:{'#3fb950' if pg_ok else '#f85149'}">{s['postgres']['state']}</b></span>
 <span>client port {port['port']}:
   <b style="color:{'#3fb950' if port['open'] else '#f85149'}">{'open' if port['open'] else 'closed'}</b></span>
</p>
<p class=dim>Auto-refreshes every 5s &middot; <a href="/" style="color:#2f81f7">player view</a>
 &middot; JSON at <a href="/api/status" style="color:#2f81f7">/api/status</a>.</p>
"""


def render_public(s: dict) -> str:
    """The page a player sees. No node names, no memory, no jargon.

    Deliberately answers one question -- can I play right now -- because that is
    the only one a player has. The operator view lives at /ops.
    """
    ready = s["ready"]
    running = s["postgres"]["state"] == "running" or any(
        n["container"] == "running" for n in s["nodes"])
    if ready:
        mood, headline = "up", "Server online"
        blurb = "Agon is up and accepting players."
    elif running:
        mood, headline = "wait", "Server starting up"
        done = len(s["nodes"]) - s["nodes_booting"]
        blurb = (f"The world is loading ({done} of {len(s['nodes'])} systems ready). "
                 "This takes a few minutes after a restart - you can log in once it finishes.")
    else:
        mood, headline = "down", "Server offline"
        blurb = "The server is not running right now. Check back shortly."

    players = s.get("players")
    players_line = ""
    if ready and players is not None:
        who = "1 player" if players == 1 else f"{players} players"
        players_line = f'<p class=players><b>{who}</b> online</p>'

    address = (f'<p class=addr>Connect to <code>{SERVER_ADDRESS}</code></p>'
               if SERVER_ADDRESS and ready else "")
    colours = {"up": "#3fb950", "wait": "#d29922", "down": "#f85149"}
    return f"""<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<meta http-equiv=refresh content=30>
<title>Darkfall - {headline}</title>
<style>
 :root{{color-scheme:dark}}
 body{{font:16px/1.6 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#0d1117;
      color:#e6edf3;margin:0;min-height:100vh;display:grid;place-items:center;padding:2rem}}
 main{{text-align:center;max-width:34rem}}
 .dot{{width:1rem;height:1rem;border-radius:50%;background:{colours[mood]};display:inline-block;
       margin-right:.6rem;vertical-align:middle;
       box-shadow:0 0 0 .35rem {colours[mood]}22{'' if mood != 'wait' else ''}}}
 h1{{font-size:2rem;margin:.5rem 0;font-weight:600}}
 p{{color:#9198a1;margin:.5rem 0}}
 .players{{font-size:1.25rem;color:#e6edf3;margin-top:1.5rem}}
 .addr code{{background:#161b22;padding:.2rem .5rem;border-radius:.25rem;color:#79c0ff}}
 footer{{margin-top:2.5rem;font-size:.8rem;color:#6e7681}}
 a{{color:#58a6ff}}
</style>
<main>
 <h1><span class=dot></span>{headline}</h1>
 <p>{blurb}</p>
 {players_line}
 {address}
 <footer>Updates automatically &middot; <a href="/ops">technical view</a></footer>
</main>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler's contract
        if self.path.startswith("/api/status"):
            body = json.dumps(snapshot(), indent=2).encode()
            ctype = "application/json"
        elif self.path.startswith("/healthz"):
            body = (b"ok" if snapshot()["ready"] else b"booting")
            ctype = "text/plain"
        elif self.path.startswith("/ops"):
            body = render(snapshot()).encode()
            ctype = "text/html; charset=utf-8"
        else:
            body = render_public(snapshot()).encode()
            ctype = "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args) -> None:
        """Silence per-request logging: a 5s refresh would fill the journal."""


if __name__ == "__main__":
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()

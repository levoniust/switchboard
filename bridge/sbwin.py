"""Windows terminal backend for the Switchboard node: talks to sbkeeper (which holds the chats) over 127.0.0.1.

Same method names as sbcore.Tmux, so the bridge code doesn't care which one it has. Sync methods are called from
worker threads (asyncio.to_thread), attach() from the event loop.
"""
import asyncio
import json
import os
import re
import urllib.error
import urllib.request

import sbcore

_WIN_CMD_RE = re.compile(r"^[A-Za-z0-9_./\\: -]*$")
SHELL_ARGV = ["powershell.exe", "-NoLogo"]


class KeeperError(RuntimeError):
    pass


class KeeperBackend:
    def __init__(self, cfg, home=None):
        home = home or sbcore.config_dir()
        port, self.key = open(os.path.join(home, "keeper.key")).read().split()
        self.base = f"http://127.0.0.1:{port}"
        self.cfg = cfg

    # ---- HTTP to sbkeeper
    def _req(self, method, path, body=None, timeout=10):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method,
                                     headers={"X-Keeper-Key": self.key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read() or b"null")
        except urllib.error.HTTPError as e:
            raise KeeperError(f"sbkeeper {method} {path}: {e.code} {e.read()[:200]!r}") from None
        except OSError as e:
            raise KeeperError(f"sbkeeper not reachable: {e}") from None

    # ---- what the bridge calls (mirrors sbcore.Tmux)
    def ensure_session(self):
        pass  # sbkeeper has no session to create

    def cleanup_views(self):
        pass  # no view sessions on Windows

    def windows(self):
        try:
            return self._req("GET", "/windows")
        except KeeperError:
            return []

    def new_window(self, name, cwd, command):
        r = self._req("POST", "/windows", {"name": name, "cwd": cwd, "argv": command["argv"], "env": command["env"],
                                           "cols": 120, "rows": 40})
        return r["id"], r["pane"]

    def rename(self, wid, name):
        self._req("POST", f"/windows/{_q(wid)}/rename", {"name": name})

    def kill(self, wid):
        self._req("DELETE", f"/windows/{_q(wid)}")

    def send_keys(self, pane, keys=(), literal=None):
        self._req("POST", f"/panes/{_q(pane)}/keys", {"keys": list(keys), "literal": literal})

    def pane_info(self, pane):
        try:
            return self._req("GET", f"/panes/{_q(pane)}/info")
        except KeeperError:
            return None

    def _lines(self, pane, n, esc):
        try:
            return self._req("GET", f"/panes/{_q(pane)}/lines?n={int(n)}&esc={1 if esc else 0}", timeout=30)["lines"]
        except KeeperError:
            return []

    def capture(self, pane, lines=60):
        return "\n".join(self._lines(pane, lines, False)) + "\n"

    def snapshot(self, pane, lines=2000):
        return self._lines(pane, lines, True)

    def kill_session(self, name):
        pass

    # ---- launchers
    def command_for(self, kind, cfg):
        """argv + env for a new chat. Launcher commands run in PowerShell, which stays open when they exit
        (like `exec bash` on Linux)."""
        l = next((l for l in sbcore.launchers(cfg or {}, cmd_re=_WIN_CMD_RE) if l["kind"] == kind), None)
        if not l or not l["command"]:
            return {"argv": SHELL_ARGV, "env": {}}
        env = {"CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN": "1"} if l["claude"] else {}
        return {"argv": SHELL_ARGV + ["-NoExit", "-ExecutionPolicy", "Bypass", "-Command", f"& {l['command']}"],
                "env": env}

    def detect_kind(self, pid, cfg):
        """Launcher kind from the claude.exe under the chat's shell (its environment, through psutil)."""
        try:
            import psutil
            procs = psutil.Process(pid).children(recursive=True)
        except Exception:
            return "shell"
        for p in procs:
            try:
                name = p.name().lower()
                if name not in ("claude.exe", "claude") and not any(
                        os.path.basename(c).lower() in ("claude", "claude.exe") for c in p.cmdline()[:2]):
                    continue
                env = p.environ()
            except Exception:
                continue
            return sbcore.kind_from_env(env, cfg)
        return "shell"

    async def attach(self, w, mode, cols, rows):
        att = KeeperAttach(self, w["pane"], mode)
        await att.open()
        if mode == "live":
            att.resize(cols, rows)
        return att


class KeeperAttach:
    """The app's terminal stream through sbkeeper. Same interface as switchboard.PtyAttach."""

    def __init__(self, backend, pane, mode):
        self.b, self.pane, self.mode = backend, pane, mode
        self.session = self.ws = None

    async def open(self):
        from aiohttp import ClientSession
        self.session = ClientSession()
        self.ws = await self.session.ws_connect(f"{self.b.base}/panes/{_q(self.pane)}/attach",
                                                headers={"X-Keeper-Key": self.b.key}, max_msg_size=4 * 1024 * 1024)

    async def read(self):
        from aiohttp import WSMsgType
        msg = await self.ws.receive()
        return msg.data if msg.type == WSMsgType.BINARY else b""

    async def write(self, data):
        if not self.ws.closed:
            await self.ws.send_bytes(bytes(data))

    def resize(self, c, r):
        # fixed/reader: the chat keeps its own size (like tmux ignore-size); only live mode resizes it
        if self.mode == "live" and not self.ws.closed:
            asyncio.ensure_future(self.ws.send_str(json.dumps({"resize": [int(c), int(r)]})))

    async def close(self):
        if self.ws is not None:
            await self.ws.close()
        if self.session is not None:
            await self.session.close()


def _q(s):
    return urllib.request.quote(str(s), safe="")

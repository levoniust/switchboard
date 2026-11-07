#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["aiohttp>=3.9,<4", "pyte>=0.8", "pywinpty>=2.0; sys_platform == 'win32'"]
# ///
"""sbkeeper: holds Switchboard chats open on Windows (the job tmux does on Linux).

Each chat is a ConPTY console (pywinpty) whose output feeds a pyte terminal emulator with 50 000 lines of
scrollback. The node (switchboard.py) talks to it over 127.0.0.1 with a shared key; it can restart or update
without ending any chat. Keep this file small and boring: updating it ends every open chat.

usage: sbkeeper.py [--port 8097]          key: <switchboard home>/keeper.key (created on first run)

API (header X-Keeper-Key):
  GET    /windows                         list of chats
  POST   /windows {name,cwd,argv,env,cols,rows}  -> {id, pane}
  POST   /windows/{id}/rename {name}      DELETE /windows/{id}
  POST   /panes/{pane}/keys {keys, literal}
  GET    /panes/{pane}/info               {w, h, hist, alt}
  GET    /panes/{pane}/lines?n=N&esc=1    scrollback + screen as text lines (SGR colours with esc=1)
  POST   /panes/{pane}/resize {cols,rows}
  WS     /panes/{pane}/attach             binary out = terminal output (starts with a repaint), binary in = keys,
                                          text in {"resize": [cols, rows]}
"""
import argparse
import asyncio
import codecs
import json
import logging
import os
import secrets
import subprocess
import sys
import threading
import time

import pyte
from aiohttp import WSMsgType, web

log = logging.getLogger("sbkeeper")
IS_WINDOWS = os.name == "nt"
HISTORY = 50000

# tmux key names the node sends (answering prompts, the keys API) -> what the terminal expects
KEYS = {"Enter": "\r", "Escape": "\x1b", "Tab": "\t", "BTab": "\x1b[Z", "BSpace": "\x7f", "Space": " ",
        "Up": "\x1b[A", "Down": "\x1b[B", "Right": "\x1b[C", "Left": "\x1b[D", "Home": "\x1b[H", "End": "\x1b[F",
        "PageUp": "\x1b[5~", "PageDown": "\x1b[6~", "DC": "\x1b[3~"}


def key_bytes(name):
    if name in KEYS:
        return KEYS[name]
    if len(name) == 3 and name.startswith("C-") and name[2].isalpha():
        return chr(ord(name[2].lower()) - 96)
    return name  # anything else is typed as-is (digits, letters), like tmux does


# ---------------------------------------------------------------- PTYs

class WinPty:
    """ConPTY through pywinpty."""

    def __init__(self, argv, cwd, env, cols, rows):
        from winpty import PtyProcess
        self.p = PtyProcess.spawn(argv, cwd=cwd, env=env, dimensions=(rows, cols))
        self.pid = self.p.pid

    def read(self):
        return self.p.read(65536)  # str; raises EOFError at the end

    def write(self, text):
        self.p.write(text)

    def resize(self, cols, rows):
        self.p.setwinsize(rows, cols)

    def alive(self):
        return self.p.isalive()

    def kill(self):
        try:
            self.p.terminate(force=True)
        except Exception:
            pass


class PosixPty:
    """Same interface on Linux, so the keeper can be tested off Windows."""

    def __init__(self, argv, cwd, env, cols, rows):
        import fcntl, struct, termios  # noqa: E401
        self._fcntl, self._struct, self._termios = fcntl, struct, termios
        self.mfd, sfd = os.openpty()
        self.resize_fd(sfd, cols, rows)
        self.proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=sfd, stdout=sfd, stderr=sfd, start_new_session=True)
        os.close(sfd)
        self.pid = self.proc.pid
        self.dec = codecs.getincrementaldecoder("utf-8")("replace")

    def resize_fd(self, fd, cols, rows):
        self._fcntl.ioctl(fd, self._termios.TIOCSWINSZ, self._struct.pack("HHHH", rows, cols, 0, 0))

    def read(self):
        try:
            data = os.read(self.mfd, 65536)
        except OSError:
            data = b""
        if not data:
            raise EOFError
        return self.dec.decode(data)

    def write(self, text):
        os.write(self.mfd, text.encode())

    def resize(self, cols, rows):
        self.resize_fd(self.mfd, cols, rows)

    def alive(self):
        return self.proc.poll() is None

    def kill(self):
        try:
            self.proc.kill()
        except Exception:
            pass


# ---------------------------------------------------------------- rendering (pyte screen -> text lines)

_NAMED = {"black": 0, "red": 1, "green": 2, "brown": 3, "yellow": 3, "blue": 4, "magenta": 5, "cyan": 6, "white": 7}


def _color(c, base):
    """SGR parameters for a pyte colour (base 30 = fg, 40 = bg); [] for the default."""
    if not c or c == "default":
        return []
    if c in _NAMED:
        return [str(base + _NAMED[c])]
    if c.startswith("bright") and c[6:] in _NAMED:
        return [str(base + 60 + _NAMED[c[6:]])]
    if len(c) == 6:
        try:
            return [str(base + 8), "2", str(int(c[0:2], 16)), str(int(c[2:4], 16)), str(int(c[4:6], 16))]
        except ValueError:
            return []
    return []


def _sgr(a):
    fg, bg, bold, ital, under, rev = a
    p = ["0"]
    if bold:
        p.append("1")
    if ital:
        p.append("3")
    if under:
        p.append("4")
    if rev:
        p.append("7")
    return "\x1b[" + ";".join(p + _color(fg, 30) + _color(bg, 40)) + "m"


_PLAIN = ("default", "default", False, False, False, False)


def render_line(line, width, esc):
    """One pyte line (dict column -> Char) as text, trailing blanks removed, SGR escapes when esc."""
    cells = []
    for x in range(width):
        ch = line[x]
        if ch.data == "":
            continue  # right half of a wide character
        cells.append((ch.data, (ch.fg, ch.bg, ch.bold, ch.italics, ch.underscore, ch.reverse)))
    while cells and cells[-1][0] == " " and cells[-1][1][1] == "default" and not cells[-1][1][5]:
        cells.pop()
    if not esc:
        return "".join(d for d, _ in cells)
    out, cur = [], _PLAIN
    for d, a in cells:
        if a != cur:
            out.append(_sgr(a))
            cur = a
        out.append(d)
    if cur != _PLAIN:
        out.append("\x1b[0m")
    return "".join(out)


# ---------------------------------------------------------------- one chat

class Chat:
    def __init__(self, n, name, cwd, argv, env, cols, rows, pty_cls):
        self.n, self.name, self.cwd, self.argv = n, name, cwd, argv
        self.id, self.pane = f"@{n}", f"%{n}"
        self.cols, self.rows = cols, rows
        self.lock = threading.Lock()
        self.screen = pyte.HistoryScreen(cols, rows, history=HISTORY, ratio=0.5)
        self.stream = pyte.Stream(self.screen)
        self.activity = time.time()
        self.created = time.time()
        self.listeners = set()  # asyncio queues of attached viewers
        self.loop = None
        self.dead = False
        full_env = dict(os.environ, **(env or {}), SWITCHBOARD_PANE=self.pane, TERM="xterm-256color",
                        COLORTERM="truecolor")
        self.pty = pty_cls(argv, cwd, full_env, cols, rows)
        # answer terminal queries (cursor position etc.): ConPTY asks at start-up and waits for the reply
        self.screen.write_process_input = lambda s: self._write(s)
        self.thread = threading.Thread(target=self._read_loop, daemon=True, name=f"chat{n}")

    def start(self, loop, on_exit):
        self.loop, self.on_exit = loop, on_exit
        self.thread.start()

    def _write(self, text):
        try:
            self.pty.write(text)
        except Exception as e:  # the process just exited
            log.debug("write to %s: %s", self.pane, e)

    def _read_loop(self):
        while True:
            try:
                data = self.pty.read()
            except (EOFError, OSError):
                break
            if not data:
                if not self.pty.alive():
                    break
                time.sleep(0.02)
                continue
            with self.lock:
                self.stream.feed(data)
                self.activity = time.time()
            raw = data.encode("utf-8", "replace")
            self.loop.call_soon_threadsafe(self._fanout, raw)
        self.dead = True
        self.loop.call_soon_threadsafe(self._fanout, b"")
        self.loop.call_soon_threadsafe(self.on_exit, self)

    def _fanout(self, raw):
        for q in list(self.listeners):
            q.put_nowait(raw)

    def info(self):
        with self.lock:
            return {"w": self.screen.columns, "h": self.screen.lines, "hist": len(self.screen.history.top),
                    "alt": False}

    def lines(self, n, esc):
        """Last n lines of scrollback + screen (like `tmux capture-pane -S -n`), trailing blank lines dropped."""
        with self.lock:
            s = self.screen
            want_hist = max(0, n - s.lines)
            top = list(s.history.top)[-want_hist:] if want_hist else []
            rows = [render_line(l, max([s.columns] + [k + 1 for k in l.keys()]), esc) for l in top]
            rows += [render_line(s.buffer[y], s.columns, esc) for y in range(s.lines)]
        while rows and not rows[-1].strip():
            rows.pop()
        return rows

    def repaint(self):
        """Escape sequence that draws the current screen on a fresh viewer's terminal."""
        with self.lock:
            s = self.screen
            body = "\r\n".join(render_line(s.buffer[y], s.columns, True) for y in range(s.lines))
            cur = f"\x1b[{s.cursor.y + 1};{s.cursor.x + 1}H" + ("\x1b[?25l" if s.cursor.hidden else "\x1b[?25h")
        return ("\x1b[0m\x1b[H\x1b[2J" + body + cur).encode()

    def resize(self, cols, rows):
        cols, rows = max(10, min(1000, int(cols))), max(5, min(500, int(rows)))
        with self.lock:
            if (cols, rows) == (self.screen.columns, self.screen.lines):
                return
            self.screen.resize(rows, cols)
        self.pty.resize(cols, rows)

    def send(self, keys=(), literal=None):
        if literal:
            self._write(literal)
        for k in keys:
            self._write(key_bytes(k))

    def view(self, index):
        return {"id": self.id, "index": index, "name": self.name, "pane": self.pane, "pid": self.pty.pid,
                "cwd": self.cwd, "command": os.path.basename(str(self.argv[0] if isinstance(self.argv, list) else self.argv)),
                "activity": int(self.activity), "dead": self.dead}


# ---------------------------------------------------------------- server

class Keeper:
    def __init__(self, key, pty_cls=None):
        self.key = key
        self.pty_cls = pty_cls or (WinPty if IS_WINDOWS else PosixPty)
        self.chats = {}  # id -> Chat, in creation order
        self.n = 0

    def chat(self, ref):
        for c in self.chats.values():
            if ref in (c.id, c.pane):
                return c
        raise web.HTTPNotFound(text="no such chat")

    def _exited(self, chat):
        # like tmux: a window whose program ended goes away
        self.chats.pop(chat.id, None)
        log.info("chat %s (%s) ended", chat.id, chat.name)

    async def list(self, request):
        return web.json_response([c.view(i) for i, c in enumerate(self.chats.values())])

    async def create(self, request):
        b = await request.json()
        self.n += 1
        argv = b.get("argv") or (["powershell.exe", "-NoLogo"] if IS_WINDOWS else ["bash", "-l"])
        cwd = b.get("cwd") or os.path.expanduser("~")
        chat = await asyncio.to_thread(Chat, self.n, str(b.get("name") or "chat")[:40], cwd, argv, b.get("env") or {},
                                       int(b.get("cols") or 120), int(b.get("rows") or 40), self.pty_cls)
        self.chats[chat.id] = chat
        chat.start(asyncio.get_running_loop(), self._exited)
        log.info("chat %s (%s) started: %s", chat.id, chat.name, argv)
        return web.json_response({"id": chat.id, "pane": chat.pane})

    async def rename(self, request):
        self.chat(request.match_info["id"]).name = str((await request.json()).get("name", ""))[:40]
        return web.json_response({"ok": True})

    async def kill(self, request):
        c = self.chat(request.match_info["id"])
        await asyncio.to_thread(c.pty.kill)
        self.chats.pop(c.id, None)
        return web.json_response({"ok": True})

    async def keys(self, request):
        b = await request.json()
        c = self.chat(request.match_info["pane"])
        await asyncio.to_thread(c.send, [k for k in b.get("keys", []) if isinstance(k, str)], b.get("literal"))
        return web.json_response({"ok": True})

    async def info(self, request):
        return web.json_response(self.chat(request.match_info["pane"]).info())

    async def lines(self, request):
        c = self.chat(request.match_info["pane"])
        n = max(1, min(HISTORY + 1000, int(request.query.get("n", "60"))))
        rows = await asyncio.to_thread(c.lines, n, request.query.get("esc") == "1")
        return web.json_response({"lines": rows})

    async def resize(self, request):
        b = await request.json()
        await asyncio.to_thread(self.chat(request.match_info["pane"]).resize, b["cols"], b["rows"])
        return web.json_response({"ok": True})

    async def attach(self, request):
        c = self.chat(request.match_info["pane"])
        ws = web.WebSocketResponse(heartbeat=20, max_msg_size=4 * 1024 * 1024)
        await ws.prepare(request)
        q = asyncio.Queue()
        c.listeners.add(q)

        async def pump():
            await ws.send_bytes(await asyncio.to_thread(c.repaint))
            while True:
                data = await q.get()
                if not data:
                    break
                while not q.empty() and len(data) < 256 * 1024:
                    nxt = q.get_nowait()
                    if not nxt:
                        q.put_nowait(b"")
                        break
                    data += nxt
                if ws.closed:
                    return
                await ws.send_bytes(data)
            await ws.close()

        task = asyncio.ensure_future(pump())
        try:
            async for msg in ws:
                if msg.type == WSMsgType.BINARY:
                    await asyncio.to_thread(c._write, msg.data.decode("utf-8", "replace"))
                elif msg.type == WSMsgType.TEXT:
                    m = json.loads(msg.data)
                    if "resize" in m:
                        await asyncio.to_thread(c.resize, *m["resize"])
        finally:
            c.listeners.discard(q)
            task.cancel()
        return ws


def make_app(keeper):
    @web.middleware
    async def auth(request, handler):
        if not secrets.compare_digest(request.headers.get("X-Keeper-Key", "").encode(), keeper.key.encode()):
            raise web.HTTPForbidden()
        return await handler(request)

    app = web.Application(middlewares=[auth])
    r = app.router
    r.add_get("/windows", keeper.list)
    r.add_post("/windows", keeper.create)
    r.add_post("/windows/{id}/rename", keeper.rename)
    r.add_delete("/windows/{id}", keeper.kill)
    r.add_post("/panes/{pane}/keys", keeper.keys)
    r.add_get("/panes/{pane}/info", keeper.info)
    r.add_get("/panes/{pane}/lines", keeper.lines)
    r.add_post("/panes/{pane}/resize", keeper.resize)
    r.add_get("/panes/{pane}/attach", keeper.attach)
    return app


def home_dir():
    default = os.path.join(os.environ.get("LOCALAPPDATA", "~"), "switchboard") if IS_WINDOWS else "~/.config/switchboard"
    return os.path.expanduser(os.environ.get("SWITCHBOARD_HOME", default))


def load_key(home):
    """keeper.key = "<port> <key>", shared with the node. Created on first run, readable by this user only."""
    path = os.path.join(home, "keeper.key")
    if not os.path.exists(path):
        os.makedirs(home, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(f"8097 {secrets.token_hex(24)}\n")
    port, key = open(path).read().split()
    return int(port), key


async def serve(port, key):
    keeper = Keeper(key)
    runner = web.AppRunner(make_app(keeper), access_log=None)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", port).start()
    log.info("sbkeeper on 127.0.0.1:%s", port)
    while True:
        await asyncio.sleep(3600)


def main():
    ap = argparse.ArgumentParser(prog="sbkeeper")
    ap.add_argument("--port", type=int)
    a = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                        filename=os.path.join(home_dir(), "sbkeeper.log") if IS_WINDOWS else None)
    port, key = load_key(home_dir())
    asyncio.run(serve(a.port or port, key))


if __name__ == "__main__":
    sys.exit(main())

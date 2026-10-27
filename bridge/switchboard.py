#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["aiohttp>=3.9,<4", "segno>=1.6"]
# ///
"""Switchboard bridge: lets the Switchboard Android app drive Claude Code / claude-local chats living in tmux.

usage:
  switchboard.py init [--hosts 192.168.1.10,100.x.y.z] [--ha-url URL --ha-notify mobile_app_x]   create config, token, TLS cert
  switchboard.py serve                                                                           run the bridge (systemd --user)
  switchboard.py pair                                                                            show the pairing link / QR
  switchboard.py download-link                                                                   one-time APK + pairing page link
  switchboard.py push [on|off|test]                                                              phone notifications via Home Assistant
"""
import argparse
import asyncio
import base64
import fcntl
import hashlib
import json
import logging
import os
import secrets
import signal
import ssl
import struct
import subprocess
import sys
import termios
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sbcore  # noqa: E402

from aiohttp import WSMsgType, web, ClientSession, ClientTimeout  # noqa: E402

log = logging.getLogger("switchboard")
VERSION = "1.1.0"


# ---------------------------------------------------------------- setup commands

def cmd_init(a):
    d = sbcore.config_dir()
    os.makedirs(d, mode=0o700, exist_ok=True)
    path = os.path.join(d, "config.json")
    cfg = json.load(open(path)) if os.path.exists(path) else {}
    hosts = [h for h in (a.hosts or "").split(",") if h] or cfg.get("hosts") or _guess_hosts()
    cfg.update({"hosts": hosts, "port": a.port or cfg.get("port", 8095), "hook_port": cfg.get("hook_port", 8096),
                "tmux_session": a.tmux_session or cfg.get("tmux_session", "AI"),
                "roots": cfg.get("roots") or [os.path.expanduser("~")], "name": cfg.get("name") or os.uname().nodename})
    cfg.setdefault("token", sbcore.new_token())
    cfg.setdefault("hook_key", secrets.token_hex(16))
    push = cfg.setdefault("push", {})
    if a.ha_url:
        push.update(ha_url=a.ha_url, ha_notify=a.ha_notify, ha_token_file=a.ha_token_file or "~/.ha_token", enabled=True)
    if a.vigil_url:
        cfg["vigil_url"] = a.vigil_url
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(path, 0o600)
    with open(os.path.join(d, "hook.key"), "w") as f:
        f.write(f"{cfg['hook_port']} {cfg['hook_key']}\n")
    os.chmod(os.path.join(d, "hook.key"), 0o600)
    cert, key = os.path.join(d, "cert.pem"), os.path.join(d, "key.pem")
    if not os.path.exists(cert) or a.new_cert:
        san = ",".join([f"IP:{h}" if h.replace(".", "").isdigit() else f"DNS:{h}" for h in hosts] + ["IP:127.0.0.1"])
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                        "-days", "3650", "-subj", f"/CN=switchboard-{cfg['name']}", "-addext", f"subjectAltName={san}",
                        "-keyout", key, "-out", cert], check=True, capture_output=True)
        os.chmod(key, 0o600)
    print(f"config: {path}\nhosts: {', '.join(hosts)}  port: {cfg['port']}\ncert pin: {cert_pin(cert)}")


def _guess_hosts():
    out = subprocess.run(["hostname", "-I"], capture_output=True, text=True).stdout.split()
    return [h for h in out if h.count(".") == 3]


def cert_pin(cert_path):
    pem = open(cert_path).read()
    der = ssl.PEM_cert_to_DER_cert(pem)
    return hashlib.sha256(der).hexdigest()


def pair_payload(cfg):
    d = sbcore.config_dir()
    p = {"v": 1, "n": cfg["name"], "h": cfg["hosts"], "p": cfg["port"], "t": cfg["token"],
         "c": cert_pin(os.path.join(d, "cert.pem"))}
    return base64.urlsafe_b64encode(json.dumps(p, separators=(",", ":")).encode()).decode().rstrip("=")


def cmd_pair(a):
    import segno
    cfg = sbcore.load_config()
    link = "switchboard://pair/" + pair_payload(cfg)
    print("Pairing link (contains the access token - treat it like a password):\n")
    print(link + "\n")
    segno.make(link, error="l").terminal(compact=True)


def cmd_push(a):
    """switchboard push on|off|test: phone notifications through Home Assistant."""
    path = os.path.join(sbcore.config_dir(), "config.json")
    cfg = json.load(open(path))
    push = cfg.setdefault("push", {})
    if a.state in ("on", "off"):
        push["enabled"] = a.state == "on"
        json.dump(cfg, open(path, "w"), indent=2)
        subprocess.run(["systemctl", "--user", "restart", "switchboard"], check=False)
        print(f"phone push {'ON' if push['enabled'] else 'OFF'} (bridge restarted)")
    elif a.state == "test":
        ok = sbcore.ha_push(dict(push, enabled=True), {"id": 0, "type": "done", "title": "Test", "pane": "",
                                                        "body": "Switchboard can reach your phone.", "session_name": "Switchboard"})
        print("sent" if ok else "not configured (ha_url / ha_notify missing)")
    else:
        print(f"phone push is {'ON' if push.get('enabled') else 'OFF'} via {push.get('ha_notify') or 'nothing'}")


def cmd_download_link(a):
    cfg = sbcore.load_config()
    code = secrets.token_urlsafe(18)
    d = sbcore.config_dir()
    codes_path = os.path.join(d, "download-codes.json")
    codes = json.load(open(codes_path)) if os.path.exists(codes_path) else {}
    codes = {k: v for k, v in codes.items() if v > time.time()}
    codes[code] = time.time() + 48 * 3600
    json.dump(codes, open(codes_path, "w"))
    os.chmod(codes_path, 0o600)
    for h in cfg["hosts"]:
        print(f"https://{h}:{cfg['port']}/get/{code}")
    print("(one-time link, valid 48 h; the browser will warn about the self-signed certificate)")


# ---------------------------------------------------------------- server

class Bridge:
    def __init__(self, cfg):
        self.cfg = cfg
        self.dir = sbcore.config_dir()
        self.tmux = sbcore.Tmux(cfg["tmux_session"])
        self.store = sbcore.Store(os.path.join(self.dir, "alerts.db"))
        self.sessions = sbcore.Sessions(self.store, on_alert=self._on_alert, on_change=self._on_change)
        self.clients = set()          # event websockets
        self.focus = {}               # ws -> pane the app is looking at (foreground)
        self.loop = None
        self.http = None
        # a restart must not forget prompts that are still waiting for an answer
        for a in reversed(self.store.list("state='open' AND type IN ('permission','question')")):
            if a.get("pane"):
                self.sessions.get(a["pane"]).update(status=a["type"], pending=a["id"], kind=a.get("kind"))

    # ---- helpers
    def auth_ok(self, request):
        tok = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
        tok = tok or request.query.get("token", "") or request.cookies.get("sb", "")
        return secrets.compare_digest(tok, self.cfg["token"])

    def window_for(self, wid):
        for w in self.tmux.windows():
            if wid in (w["id"], w["pane"], str(w["index"])):
                return w
        raise web.HTTPNotFound(text="no such session")

    def session_view(self, w):
        st = self.sessions.get(w["pane"])
        kind = st.get("kind") or sbcore.detect_kind(w["pid"])
        st["kind"] = kind
        pending = self.store.get(st["pending"]) if st.get("pending") else None
        return {"id": w["id"], "index": w["index"], "name": w["name"], "pane": w["pane"], "cwd": w["cwd"],
                "command": w["command"], "kind": kind, "model": st.get("model"), "status": st.get("status", "idle"),
                "last": st.get("last", ""), "activity": w["activity"], "updated": st.get("updated"), "pending": pending}

    def broadcast(self, msg):
        data = json.dumps(msg)
        for ws in list(self.clients):
            if not ws.closed:
                asyncio.ensure_future(ws.send_str(data))

    def _on_change(self, pane, st):
        if self.loop:
            self.loop.call_soon_threadsafe(self.broadcast, {"type": "status", "pane": pane, "status": st.get("status"),
                                                            "pending": st.get("pending"), "last": st.get("last", "")})

    def _on_alert(self, alert):
        if not self.loop:
            return
        self.loop.call_soon_threadsafe(self.broadcast, {"type": "alert", "alert": alert})
        # the app is in the foreground ("*") or showing exactly this chat: it shows the alert itself, no push
        watching = any(p in ("*", alert.get("pane")) for ws, p in self.focus.items() if not ws.closed)
        if not watching:
            self.loop.run_in_executor(None, self._push, alert)

    def _push(self, alert):
        try:
            sbcore.ha_push(self.cfg.get("push", {}), alert)
        except Exception as e:  # never let push problems break the bridge
            log.warning("push failed: %s", e)

    # ---- hook listener (127.0.0.1 only)
    async def hook(self, request):
        if request.headers.get("X-Switchboard-Key") != self.cfg["hook_key"]:
            raise web.HTTPForbidden()
        ev = await request.json()
        pane = ev.pop("_pane", "") or ""
        hint = ev.pop("_kind", None)
        meta = {"pane": pane}
        if pane:
            # a pane counts if it is one of the chat windows (asking tmux for the pane's session is wrong:
            # while the phone looks at a chat, tmux names the phone's grouped view session instead)
            w = next((w for w in await asyncio.to_thread(self.tmux.windows) if w["pane"] == pane), None)
            if not w:
                return web.json_response({"ok": True, "ignored": "not a Switchboard tmux pane"})
            meta.update(window=w["id"], title=w["name"], kind=hint or sbcore.detect_kind(w["pid"]))
        alert = self.sessions.hook(ev, meta)
        return web.json_response({"ok": True, "alert": alert["id"] if alert else None})

    # ---- REST
    async def info(self, request):
        return web.json_response({"name": self.cfg["name"], "version": VERSION, "kinds": sbcore.KINDS,
                                  "roots": self.cfg["roots"], "vigil": bool(self.cfg.get("vigil_url"))})

    async def list_sessions(self, request):
        wins = await asyncio.to_thread(self.tmux.windows)
        return web.json_response([self.session_view(w) for w in wins])

    async def create_session(self, request):
        body = await request.json()
        kind = body.get("kind", "claude")
        if kind not in sbcore.KINDS:
            raise web.HTTPBadRequest(text="unknown kind")
        cwd = self._safe_path(body.get("cwd") or self.cfg["roots"][0])
        name = (body.get("name") or {"claude": "claude", "claude-local": "qwen", "shell": "shell"}[kind])[:40]
        await asyncio.to_thread(self.tmux.ensure_session)
        wid, pane = await asyncio.to_thread(self.tmux.new_window, name, cwd, sbcore.command_for(kind))
        self.sessions.get(pane)["kind"] = kind
        self.broadcast({"type": "sessions"})
        return web.json_response({"id": wid, "pane": pane})

    async def rename_session(self, request):
        w = self.window_for(request.match_info["sid"])
        name = (await request.json()).get("name", "")[:40]
        await asyncio.to_thread(self.tmux.rename, w["id"], name)
        self.broadcast({"type": "sessions"})
        return web.json_response({"ok": True})

    async def kill_session(self, request):
        w = self.window_for(request.match_info["sid"])
        await asyncio.to_thread(self.tmux.kill, w["id"])
        self.store.close_pane(w["pane"])
        self.broadcast({"type": "sessions"})
        return web.json_response({"ok": True})

    async def send_keys(self, request):
        w = self.window_for(request.match_info["sid"])
        body = await request.json()
        keys = [k for k in body.get("keys", []) if isinstance(k, str) and len(k) < 20]
        await asyncio.to_thread(self.tmux.send_keys, w["pane"], keys, body.get("text"))
        return web.json_response({"ok": True})

    async def screen(self, request):
        w = self.window_for(request.match_info["sid"])
        text = await asyncio.to_thread(self.tmux.capture, w["pane"], int(request.query.get("lines", 60)))
        return web.json_response({"text": text, "options": sbcore.parse_options(text)})

    async def list_alerts(self, request):
        state = request.query.get("state")
        rows = self.store.list("state=?", (state,)) if state else self.store.list()
        return web.json_response(rows)

    async def get_alert(self, request):
        a = self.store.get(int(request.match_info["aid"]))
        if not a:
            raise web.HTTPNotFound()
        if a["state"] == "open" and a["type"] in ("permission", "question") and a.get("pane"):
            # the hook fires just before Claude Code draws the dialog: give the screen a moment to settle
            opts = []
            for _ in range(6):
                text = await asyncio.to_thread(self.tmux.capture, a["pane"])
                opts = sbcore.parse_options(text)
                if len(opts) >= 2:
                    break
                await asyncio.sleep(0.4)
            a["screen_options"] = [{"key": k, "label": l} for k, l in opts]
        return web.json_response(a)

    async def answer(self, request):
        """Answer a pending permission / question by pressing its number in the Claude Code dialog."""
        a = self.store.get(int(request.match_info["aid"]))
        if not a or not a.get("pane"):
            raise web.HTTPNotFound()
        if a["state"] != "open":
            return web.json_response({"ok": False, "error": f"already {a['state']}"}, status=409)
        body = await request.json()
        key = str(body.get("key", ""))
        text = await asyncio.to_thread(self.tmux.capture, a["pane"])
        opts = sbcore.parse_options(text)
        if not opts:
            return web.json_response({"ok": False, "error": "the dialog is not on screen any more"}, status=409)
        if key == "no":  # permission dialogs put "No" at different positions
            key = next((d for d, l in opts if l.lower().startswith("no")), opts[-1][0])
        if key not in [d for d, _ in opts]:
            return web.json_response({"ok": False, "error": "that choice is not on screen"}, status=409)
        await asyncio.to_thread(self.tmux.send_keys, a["pane"], [key])
        label = next((l for d, l in opts if d == key), key)
        self.sessions.answered(a["pane"], a["id"], label)
        self.broadcast({"type": "alert_closed", "id": a["id"], "answered": label})
        return web.json_response({"ok": True, "answered": label})

    async def ack_alert(self, request):
        self.store.close(int(request.match_info["aid"]), state="seen")
        return web.json_response({"ok": True})

    def _safe_path(self, path):
        real = os.path.realpath(os.path.expanduser(path))
        if not any(real == r or real.startswith(r.rstrip("/") + "/") for r in map(os.path.realpath, self.cfg["roots"])):
            raise web.HTTPForbidden(text="outside the allowed folders")
        return real

    async def list_dir(self, request):
        path = self._safe_path(request.query.get("path") or self.cfg["roots"][0])
        try:
            entries = sorted(os.scandir(path), key=lambda e: (not e.is_dir(), e.name.lower()))
        except OSError as e:
            raise web.HTTPBadRequest(text=str(e))
        items = [{"name": e.name, "dir": e.is_dir()} for e in entries if not e.name.startswith(".")][:500]
        return web.json_response({"path": path, "roots": self.cfg["roots"], "items": items})

    async def upload(self, request):
        updir = os.path.expanduser("~/switchboard/uploads")
        os.makedirs(updir, exist_ok=True)
        reader = await request.multipart()
        field = await reader.next()
        name = os.path.basename(field.filename or "upload.bin").replace(" ", "_")
        path = os.path.join(updir, f"{time.strftime('%Y%m%d-%H%M%S')}-{name}")
        size = 0
        with open(path, "wb") as f:
            while chunk := await field.read_chunk():
                size += len(chunk)
                if size > 50 * 1024 * 1024:
                    f.close(); os.unlink(path)
                    raise web.HTTPRequestEntityTooLarge(max_size=50 * 1024 * 1024, actual_size=size)
                f.write(chunk)
        return web.json_response({"path": path, "size": size})

    # ---- websockets
    async def events(self, request):
        ws = web.WebSocketResponse(heartbeat=25)
        await ws.prepare(request)
        self.clients.add(ws)
        try:
            await ws.send_str(json.dumps({"type": "hello", "version": VERSION}))
            async for msg in ws:
                if msg.type == WSMsgType.TEXT:
                    m = json.loads(msg.data)
                    if m.get("type") == "focus":
                        self.focus[ws] = m.get("pane")
        finally:
            self.clients.discard(ws)
            self.focus.pop(ws, None)
        return ws

    async def terminal(self, request):
        """Attach the app to one chat through a grouped tmux session on a PTY.
        Binary frames from the app = key bytes; text frames = JSON control ({"resize": [cols, rows]}).
        ?mode=live   (old apps) the phone's size resizes the real window and raw terminal bytes stream back.
        ?mode=fixed  the phone never resizes the window (tmux ignore-size); raw bytes stream back at the
                     window's own size, announced in {"size": [cols, rows]} text frames.
        ?mode=reader ignore-size too, but instead of raw bytes the app gets the chat's text as
                     {"drop", "keep", "tail", "w", "alt"} updates and lays it out natively."""
        w = self.window_for(request.match_info["sid"])
        mode = request.query.get("mode", "live")
        cols, rows = int(request.query.get("cols", 80)), int(request.query.get("rows", 30))
        ws = web.WebSocketResponse(heartbeat=15, max_msg_size=4 * 1024 * 1024)
        await ws.prepare(request)
        peer = request.remote
        info = await asyncio.to_thread(self.tmux.pane_info, w["pane"]) if mode != "live" else None
        if info:
            cols, rows = info["w"], info["h"]
        view = await asyncio.to_thread(self.tmux.view_session, w["id"])
        mfd, sfd = os.openpty()
        _winsize(sfd, cols, rows)
        env = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor", LANG=os.environ.get("LANG", "C.UTF-8"))
        env.pop("TMUX", None)
        attach = ["tmux", "attach-session", "-t", f"={view}"]
        if mode != "live":
            attach[2:2] = ["-f", "ignore-size"]
        proc = subprocess.Popen(attach, stdin=sfd, stdout=sfd, stderr=sfd, env=env, start_new_session=True, close_fds=True)
        os.close(sfd)
        os.set_blocking(mfd, False)
        log.info("phone attached %s to %s (%s) from %s", mode, w["name"], w["pane"], peer)
        loop = asyncio.get_running_loop()
        out_q = asyncio.Queue()

        def readable():
            try:
                data = os.read(mfd, 65536)
            except (BlockingIOError, InterruptedError):
                return
            except OSError:
                data = b""
            out_q.put_nowait(data)

        loop.add_reader(mfd, readable)

        def set_size(c, r):
            _winsize(mfd, int(c), int(r))
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGWINCH)

        async def pump():
            while True:
                data = await out_q.get()
                if not data:
                    break
                # coalesce bursts
                while not out_q.empty() and len(data) < 256 * 1024:
                    nxt = out_q.get_nowait()
                    if not nxt:
                        out_q.put_nowait(b"")
                        break
                    data += nxt
                if ws.closed:
                    break
                if mode != "reader":  # the reader gets snapshots instead; its PTY output is only drained
                    await ws.send_bytes(data)
            if not ws.closed:
                await ws.close()

        async def follow_size():
            """fixed mode: keep the phone's PTY at the window's real size and tell the app about it."""
            size = (cols, rows)
            await ws.send_str(json.dumps({"size": list(size)}))
            while not ws.closed:
                await asyncio.sleep(1)
                i = await asyncio.to_thread(self.tmux.pane_info, w["pane"])
                if i and (i["w"], i["h"]) != size:
                    size = (i["w"], i["h"])
                    set_size(*size)
                    await ws.send_str(json.dumps({"size": list(size)}))

        async def reader():
            """reader mode: send the chat's text (scrollback + screen, colours kept) whenever it changes."""
            depth, prev, prev_start, size, quiet = 2000, None, 0, (cols, rows), 0
            while not ws.closed:
                i = await asyncio.to_thread(self.tmux.pane_info, w["pane"])
                if i is None:
                    break
                if (i["w"], i["h"]) != size:
                    size = (i["w"], i["h"])
                    set_size(*size)
                lines = await asyncio.to_thread(self.tmux.snapshot, w["pane"], depth)
                start = max(0, i["hist"] - depth)
                if lines != prev:
                    d = sbcore.screen_diff(prev, lines, start - prev_start)
                    d.update(w=i["w"], alt=i["alt"])
                    await ws.send_str(json.dumps(d))
                    prev, prev_start, quiet = lines, start, 0
                else:
                    quiet += 1
                await asyncio.sleep(0.15 if quiet < 10 else 0.5)
            if not ws.closed:
                await ws.close()

        pump_task = asyncio.ensure_future(pump())
        side = {"fixed": follow_size, "reader": reader}.get(mode)
        side_task = asyncio.ensure_future(side()) if side else None
        try:
            async for msg in ws:
                if msg.type == WSMsgType.BINARY:
                    os.write(mfd, msg.data)
                elif msg.type == WSMsgType.TEXT:
                    m = json.loads(msg.data)
                    if "input" in m:
                        os.write(mfd, m["input"].encode())
                    if "resize" in m and mode == "live":
                        set_size(*m["resize"])
        finally:
            log.info("phone detached %s from %s", mode, w["name"])
            loop.remove_reader(mfd)
            pump_task.cancel()
            if side_task:
                side_task.cancel()
            try:
                proc.terminate()
                await asyncio.to_thread(proc.wait, 3)
            except Exception:
                proc.kill()
            os.close(mfd)
            await asyncio.to_thread(self.tmux.kill_session, view)
        return ws

    # ---- Vigil reverse proxy (so Vigil works away from home through the bridge)
    async def vigil(self, request):
        base = self.cfg.get("vigil_url")
        if not base:
            raise web.HTTPNotFound(text="vigil_url not configured")
        tail = request.match_info.get("tail", "")
        url = f"{base.rstrip('/')}/{tail}"
        if request.query_string:
            q = "&".join(p for p in request.query_string.split("&") if not p.startswith("token="))
            url += f"?{q}" if q else ""
        body = await request.read()
        hdrs = {k: v for k, v in request.headers.items() if k.lower() in ("content-type", "accept", "accept-language")}
        async with self.http.request(request.method, url, data=body or None, headers=hdrs, allow_redirects=False) as r:
            data = await r.read()
            out = {k: v for k, v in r.headers.items() if k.lower() in ("content-type", "cache-control", "location")}
            if "Location" in out and out["Location"].startswith("/"):
                out["Location"] = "/vigil" + out["Location"]
            if r.headers.get("content-type", "").startswith("text/html"):
                # root-relative links in Vigil's page must stay under /vigil/
                data = data.replace(b'href="/', b'href="/vigil/').replace(b'src="/', b'src="/vigil/') \
                           .replace(b"fetch('/", b"fetch('/vigil/").replace(b'fetch("/', b'fetch("/vigil/')
            resp = web.Response(body=data, status=r.status, headers=out)
        if request.query.get("token") and self.auth_ok(request):
            resp.set_cookie("sb", self.cfg["token"], httponly=True, secure=True, samesite="Strict", max_age=86400 * 365)
        return resp

    # ---- APK download + pairing page (one-time code)
    async def get_page(self, request):
        codes_path = os.path.join(self.dir, "download-codes.json")
        codes = json.load(open(codes_path)) if os.path.exists(codes_path) else {}
        code = request.match_info["code"]
        if codes.get(code, 0) < time.time():
            raise web.HTTPNotFound()
        if request.match_info.get("what") == "apk":
            apk = os.path.join(self.dir, "switchboard.apk")
            if not os.path.exists(apk):
                raise web.HTTPNotFound(text="APK not built yet")
            return web.FileResponse(apk, headers={"Content-Disposition": "attachment; filename=switchboard.apk",
                                                  "Content-Type": "application/vnd.android.package-archive"})
        link = "switchboard://pair/" + pair_payload(self.cfg)
        html = f"""<!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
<title>Switchboard</title><body style="font-family:monospace;background:#0b0f0c;color:#b8f5c0;padding:16px;line-height:1.5">
<h2>&gt; switchboard_</h2><p>1. <a style="color:#7CFF8A" href="/get/{code}/apk">Download the app (APK)</a> and install it
(allow installs from your browser when Android asks).</p>
<p>2. <a style="color:#7CFF8A" href="{link}">Pair this phone with {self.cfg['name']}</a> (opens the app).</p>
<p style="color:#6a8">This page is a one-time link. Don't share it: step 2 contains the access key.</p></body>"""
        return web.Response(text=html, content_type="text/html")


def _winsize(fd, cols, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


@web.middleware
async def auth_mw(request, handler):
    bridge = request.app["bridge"]
    path = request.path
    if path.startswith("/get/") or path == "/health":
        return await handler(request)
    if not bridge.auth_ok(request):
        raise web.HTTPUnauthorized(text="pair the app first")
    return await handler(request)


async def health(request):
    return web.json_response({"ok": True})


def make_app(bridge):
    app = web.Application(middlewares=[auth_mw], client_max_size=60 * 1024 * 1024)
    app["bridge"] = bridge
    b = bridge
    app.router.add_get("/health", health)
    app.router.add_get("/api/info", b.info)
    app.router.add_get("/api/sessions", b.list_sessions)
    app.router.add_post("/api/sessions", b.create_session)
    app.router.add_post("/api/sessions/{sid}/rename", b.rename_session)
    app.router.add_delete("/api/sessions/{sid}", b.kill_session)
    app.router.add_post("/api/sessions/{sid}/keys", b.send_keys)
    app.router.add_get("/api/sessions/{sid}/screen", b.screen)
    app.router.add_get("/api/sessions/{sid}/term", b.terminal)
    app.router.add_get("/api/alerts", b.list_alerts)
    app.router.add_get("/api/alerts/{aid}", b.get_alert)
    app.router.add_post("/api/alerts/{aid}/answer", b.answer)
    app.router.add_post("/api/alerts/{aid}/ack", b.ack_alert)
    app.router.add_get("/api/fs", b.list_dir)
    app.router.add_post("/api/upload", b.upload)
    app.router.add_get("/api/events", b.events)
    app.router.add_route("*", "/vigil/{tail:.*}", b.vigil)
    app.router.add_get("/get/{code}", b.get_page)
    app.router.add_get("/get/{code}/{what}", b.get_page)
    return app


async def serve(cfg):
    bridge = Bridge(cfg)
    bridge.loop = asyncio.get_running_loop()
    bridge.http = ClientSession(timeout=ClientTimeout(total=30))
    await asyncio.to_thread(bridge.tmux.ensure_session)
    await asyncio.to_thread(bridge.tmux.cleanup_views)

    app = make_app(bridge)
    runner = web.AppRunner(app, access_log=None)
    await runner.setup()
    ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    d = sbcore.config_dir()
    ctx.load_cert_chain(os.path.join(d, "cert.pem"), os.path.join(d, "key.pem"))
    for host in cfg["hosts"]:
        try:
            await web.TCPSite(runner, host, cfg["port"], ssl_context=ctx).start()
            log.info("listening on https://%s:%s", host, cfg["port"])
        except OSError as e:
            log.warning("cannot listen on %s:%s (%s) - is that interface up?", host, cfg["port"], e)

    hook_app = web.Application()
    hook_app.router.add_post("/hook", bridge.hook)
    hook_runner = web.AppRunner(hook_app, access_log=None)
    await hook_runner.setup()
    await web.TCPSite(hook_runner, "127.0.0.1", cfg["hook_port"]).start()
    log.info("hooks on http://127.0.0.1:%s/hook", cfg["hook_port"])

    while True:
        await asyncio.sleep(3600)
        bridge.store.prune()


def main():
    ap = argparse.ArgumentParser(prog="switchboard")
    sub = ap.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("init")
    i.add_argument("--hosts"); i.add_argument("--port", type=int); i.add_argument("--tmux-session")
    i.add_argument("--ha-url"); i.add_argument("--ha-notify"); i.add_argument("--ha-token-file")
    i.add_argument("--vigil-url"); i.add_argument("--new-cert", action="store_true")
    sub.add_parser("serve"); sub.add_parser("pair"); sub.add_parser("download-link")
    pu = sub.add_parser("push"); pu.add_argument("state", nargs="?", choices=["on", "off", "test", "status"], default="status")
    a = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if a.cmd == "init":
        cmd_init(a)
    elif a.cmd == "serve":
        asyncio.run(serve(sbcore.load_config()))
    elif a.cmd == "pair":
        cmd_pair(a)
    elif a.cmd == "download-link":
        cmd_download_link(a)
    elif a.cmd == "push":
        cmd_push(a)


if __name__ == "__main__":
    main()

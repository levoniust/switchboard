# /// script
# requires-python = ">=3.11"
# dependencies = ["aiohttp>=3.9,<4", "segno>=1.6", "pytest>=8", "pytest-asyncio>=0.23"]
# ///
"""Bridge tests. Run: uv run --script test_bridge.py  (uses a throwaway tmux session, never "AI")."""
import asyncio
import json
import os
import secrets
import ssl
import subprocess
import sys
import tempfile
import time

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sbcore  # noqa: E402

PERMISSION_SCREEN = """
 Bash command
 date > now.txt
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to /tmp/x from this project
   3. Yes, and switch to auto mode · auto mode handles these prompts for you
   4. No
 Esc to cancel · Tab to amend
"""

QUESTION_SCREEN = """
 ☐ Color
Which color do you like?
❯ 1. Red
     Choose red
  2. Green
     Choose green
  3. Blue
     Choose blue
  4. Type something.
────────────────────────────────────────
  5. Chat about this
Enter to select · ↑/↓ to navigate · Esc to cancel
"""


def test_parse_permission_options():
    opts = sbcore.parse_options(PERMISSION_SCREEN)
    assert [d for d, _ in opts] == ["1", "2", "3", "4"]
    assert opts[0][1] == "Yes" and opts[3][1] == "No"


def test_parse_question_options():
    opts = sbcore.parse_options(QUESTION_SCREEN)
    assert [d for d, _ in opts][:3] == ["1", "2", "3"]
    assert opts[1][1] == "Green"


def test_parse_nothing():
    assert sbcore.parse_options("❯ hello\n  just text\n") == []


def _sessions():
    store = sbcore.Store(":memory:")
    alerts, changes = [], []
    s = sbcore.Sessions(store, on_alert=alerts.append, on_change=lambda p, st: changes.append(st["status"]))
    return s, store, alerts


def test_screen_diff():
    def apply(lines, d):
        return lines[d["drop"]:][:d["keep"]] + d["tail"]
    a = ["l0", "l1", "l2", "> typ"]
    assert sbcore.screen_diff(None, a)["full"]
    d = sbcore.screen_diff(a, ["l0", "l1", "l2", "> typing"])
    assert (d["drop"], d["keep"], d["tail"]) == (0, 3, ["> typing"])
    # two lines scrolled off the top of the capture window and one new line arrived
    new = ["l2", "> typ", "l4", "l5"]
    d = sbcore.screen_diff(a, new, scrolled=2)
    assert (d["keep"], d["tail"]) == (2, ["l4", "l5"]) and apply(a, d) == new
    # a wrong scroll guess (or /clear) still ends with the right lines
    for guess in (-1, 0, 1, 9):
        assert apply(a, sbcore.screen_diff(a, new, scrolled=guess)) == new
    assert apply(a, sbcore.screen_diff(a, [], scrolled=0)) == []


def test_command_for_inline_screen():
    for kind in ("claude", "claude-local"):
        assert "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1" in sbcore.command_for(kind)
    assert "ALTERNATE" not in sbcore.command_for("shell")


def test_window_history_limit(bridge_env):
    cfg, home, sess = bridge_env
    t = sbcore.Tmux(session=sess)
    t.ensure_session()
    wid, pane = t.new_window("hl", home, "bash -l")
    subprocess.run(["tmux", "send-keys", "-t", pane, "-l", "for i in $(seq 1 3000); do echo L$i; done"], check=True)
    subprocess.run(["tmux", "send-keys", "-t", pane, "Enter"], check=True)
    hist, t0 = 0, time.time()
    while time.time() - t0 < 10:  # the pane must scroll past the old 2000-line default
        info = t.pane_info(pane)
        hist = (info or {}).get("hist", 0)
        if hist > 2000:
            break
        time.sleep(0.3)
    assert hist > 2000, f"scrollback stayed at {hist}: history-limit did not take effect"


def test_full_keep_len_reconstructs():
    """proto=2: window diffs applied to the full list via full_keep_len rebuild the real history,
    the cap is kept, and the phone's list is always a true suffix of it."""
    import random
    rnd = random.Random(7)
    depth, cap = 8, 40
    H = [f"h{i}" for i in range(50)]
    full, prev = list(H[-15:]), list(H[-depth:])
    prev_start = max(0, len(H) - depth)
    for _ in range(300):
        r = rnd.random()
        if r < 0.75:
            H += [f"h{len(H)}" + ("x" * rnd.randint(0, 30)) for _ in range(rnd.randint(1, 3))]
        elif r < 0.9:
            H[-1] = "redraw " + "*" * rnd.randint(1, 5)  # the screen's last lines get rewritten
        window = list(H[-depth:])
        start = max(0, len(H) - depth)
        if window != prev:
            d = sbcore.screen_diff(prev, window, start - prev_start)
            if not d["full"]:
                keep = sbcore.full_keep_len(len(full), len(prev), d)
                full = full[:keep] + d["tail"]
                trim = max(0, len(full) - cap)
                if trim:
                    full = full[trim:]
                assert full == H[len(H) - len(full):], f"step desynced: {full[-3:]} vs {H[-3:]}"
                prev = window
                prev_start = start
    assert len(full) == cap and full == H[-cap:]


@pytest.mark.asyncio
async def test_reader_proto2_deep_history(bridge_env):
    """A proto=2 Reader client gets the whole scrollback: more lines than the 2000-line window,
    including the very first ones, after the pane produced 3000 lines."""
    cfg, home, sess = bridge_env
    import switchboard
    from aiohttp import ClientSession
    task = asyncio.ensure_future(switchboard.serve(sbcore.load_config()))
    await asyncio.sleep(1.5)
    base = f"https://127.0.0.1:{cfg['port']}"
    ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    H = {"Authorization": "Bearer tok"}

    def apply(lines, m):
        if m.get("full"):
            return list(m["tail"])
        if "keep_len" in m:
            out = lines[:m["keep_len"]] + m["tail"]
            return out[m["trim"]:] if m.get("trim") else out
        return lines[m["drop"]:][:m["keep"]] + m["tail"]

    try:
        async with ClientSession() as c:
            r = await c.post(base + "/api/sessions", json={"kind": "shell", "cwd": home, "name": "deep"},
                             headers=H, ssl=ctx)
            sid = (await r.json())["id"]
            ws = await c.ws_connect(base + f"/api/sessions/{sid}/term?mode=reader&proto=2", headers=H, ssl=ctx)
            m = json.loads((await asyncio.wait_for(ws.receive(), 5)).data)
            assert m.get("full") and m.get("proto") == 2
            lines = m["tail"]
            subprocess.run(["tmux", "send-keys", "-t", f"={sess}:deep", "-l",
                            "for i in $(seq 1 3000); do echo L$i; done"], check=True)
            subprocess.run(["tmux", "send-keys", "-t", f"={sess}:deep", "Enter"], check=True)
            seen_last, t0 = False, time.time()
            while not seen_last and time.time() - t0 < 40:
                try:
                    m = await asyncio.wait_for(ws.receive(), 5)
                except (asyncio.TimeoutError, Exception):
                    break
                if isinstance(m.data, str):
                    d = json.loads(m.data)
                    if "tail" not in d:
                        continue
                    lines = apply(lines, d)
                    seen_last = any("L3000" in ln for ln in lines)
            assert seen_last, "the last line never arrived"
            assert len(lines) > 2100, f"only {len(lines)} lines: window-capped, deep history missing"
            assert any(ln.strip() == "L1" for ln in lines), "the first line is not in the history"
            await ws.close()
    finally:
        task.cancel()


def test_state_machine_permission_then_done():
    s, store, alerts = _sessions()
    meta = {"pane": "%1", "window": "@1", "title": "claude", "kind": "claude"}
    s.hook({"hook_event_name": "SessionStart", "model": "claude-haiku-5-5"}, meta)
    s.hook({"hook_event_name": "UserPromptSubmit", "prompt": "do it"}, meta)
    assert s.get("%1")["status"] == "working"
    s.hook({"hook_event_name": "PermissionRequest", "tool_name": "Bash",
            "tool_input": {"command": "date > now.txt", "description": "Write the date"}}, meta)
    s.hook({"hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "x"}, meta)
    assert len(alerts) == 1 and alerts[0]["type"] == "permission" and alerts[0]["title"] == "Write the date"
    assert s.get("%1")["status"] == "permission"
    s.hook({"hook_event_name": "PostToolUse", "tool_name": "Bash"}, meta)
    assert store.get(alerts[0]["id"])["state"] == "answered"
    s.hook({"hook_event_name": "Stop", "last_assistant_message": "All done."}, meta)
    assert alerts[-1]["type"] == "done" and alerts[-1]["body"] == "All done."
    assert s.get("%1")["status"] == "done" and s.get("%1")["model"] == "claude-haiku-5-5"


def test_state_machine_question():
    s, store, alerts = _sessions()
    meta = {"pane": "%2", "kind": "claude-local"}
    q = {"questions": [{"question": "Which color?", "header": "Color",
                        "options": [{"label": "Red", "description": "r"}, {"label": "Green", "description": "g"}]}]}
    s.hook({"hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": q}, meta)
    s.hook({"hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion", "tool_input": q}, meta)
    assert alerts[0]["type"] == "question" and [o["label"] for o in alerts[0]["options"]] == ["Red", "Green"]
    assert alerts[0]["kind"] == "claude-local"


def test_no_pane_ignored():
    s, store, alerts = _sessions()
    assert s.hook({"hook_event_name": "Stop"}, {"pane": ""}) is None and alerts == []


def test_describe_tool():
    assert sbcore.describe_tool("Edit", {"file_path": "/a/b.py"}) == ("Edit a file", "/a/b.py")


def test_push_payload(monkeypatch, tmp_path):
    sent = {}

    class R:
        status = 200
        def __enter__(self): return self
        def __exit__(self, *a): pass

    def fake_urlopen(req, timeout):
        sent["url"] = req.full_url
        sent["body"] = json.loads(req.data)
        return R()

    monkeypatch.setattr(sbcore.urllib.request, "urlopen", fake_urlopen)
    tok = tmp_path / "t"; tok.write_text("secret")
    cfg = {"enabled": True, "ha_url": "http://ha:8123", "ha_notify": "mobile_app_x", "ha_token_file": str(tok)}
    alert = {"id": 7, "type": "permission", "title": "Run a command", "body": "rm x", "pane": "%3",
             "session_name": "claude", "options": []}
    assert sbcore.ha_push(cfg, alert)
    assert sent["url"].endswith("/api/services/notify/mobile_app_x")
    d = sent["body"]["data"]
    assert d["clickAction"] == "switchboard://alert/7"
    assert [a["uri"] for a in d["actions"]] == ["switchboard://answer/7/1", "switchboard://answer/7/no"]
    assert not sbcore.ha_push({"enabled": False}, alert)


# ---------------------------------------------------------------- end-to-end against a throwaway tmux session

@pytest.fixture
def bridge_env():
    home = tempfile.mkdtemp(prefix="sbtest-")
    sess = "sbt" + secrets.token_hex(3)
    os.environ["SWITCHBOARD_HOME"] = home
    port = 20000 + secrets.randbelow(20000)
    cfg = {"hosts": ["127.0.0.1"], "port": port, "hook_port": port + 1, "tmux_session": sess,
           "roots": [home, tempfile.gettempdir()], "name": "test", "token": "tok", "hook_key": "hk", "push": {}}
    json.dump(cfg, open(os.path.join(home, "config.json"), "w"))
    open(os.path.join(home, "hook.key"), "w").write(f"{port + 1} hk\n")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                    "-days", "1", "-subj", "/CN=t", "-keyout", f"{home}/key.pem", "-out", f"{home}/cert.pem"],
                   check=True, capture_output=True)
    yield cfg, home, sess
    subprocess.run(["tmux", "kill-session", "-t", f"={sess}"], capture_output=True)
    for line in subprocess.run(["tmux", "ls", "-F", "#{session_name} #{session_group}"], capture_output=True,
                               text=True).stdout.splitlines():
        name, _, group = line.partition(" ")
        if group == sess:
            subprocess.run(["tmux", "kill-session", "-t", f"={name}"], capture_output=True)


@pytest.mark.asyncio
async def test_end_to_end(bridge_env):
    cfg, home, sess = bridge_env
    import switchboard
    from aiohttp import ClientSession
    task = asyncio.ensure_future(switchboard.serve(sbcore.load_config()))
    await asyncio.sleep(1.5)
    base = f"https://127.0.0.1:{cfg['port']}"
    ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    H = {"Authorization": "Bearer tok"}
    try:
        async with ClientSession() as c:
            r = await c.get(base + "/api/sessions", ssl=ctx)
            assert r.status == 401
            r = await c.get(base + "/api/sessions", params={"token": "tök"}, ssl=ctx)
            assert r.status == 401  # non-ASCII token: rejected, not a 500

            # download link: the pairing page (it shows the token) opens once, the APK stays downloadable
            open(os.path.join(home, "switchboard.apk"), "wb").write(b"apk")
            json.dump({"c1": time.time() + 60, "old": time.time() - 1}, open(os.path.join(home, "download-codes.json"), "w"))
            r = await c.get(base + "/get/c1", ssl=ctx)
            assert r.status == 200 and "switchboard://pair/" in await r.text()
            assert r.headers.get("Cache-Control") == "no-store"
            assert (await c.get(base + "/get/c1", ssl=ctx)).status == 410
            assert (await c.get(base + "/get/c1/apk", ssl=ctx)).status == 200
            assert (await c.get(base + "/get/old", ssl=ctx)).status == 404
            r = await c.post(base + "/api/sessions", json={"kind": "shell", "cwd": home, "name": "t1"}, headers=H, ssl=ctx)
            sid = (await r.json())["id"]
            pane = (await (await c.get(base + "/api/sessions", headers=H, ssl=ctx)).json())
            pane = next(s for s in pane if s["id"] == sid)["pane"]

            # a window opened outside the app (e.g. from a laptop) reaches the phone's event socket
            ev = await c.ws_connect(base + "/api/events", headers=H, ssl=ctx)
            await asyncio.sleep(3.5)
            subprocess.run(["tmux", "new-window", "-d", "-t", f"={sess}:", "-n", "laptop"], check=True)
            got, t0 = [], time.time()
            while "sessions" not in got and time.time() - t0 < 10:
                try:
                    m = await asyncio.wait_for(ev.receive(), 2)
                    if isinstance(m.data, str):
                        got.append(json.loads(m.data).get("type"))
                except asyncio.TimeoutError:
                    pass
            assert "sessions" in got
            await ev.close()

            # terminal over websocket: type a command, see its output
            ws = await c.ws_connect(base + f"/api/sessions/{sid}/term?cols=90&rows=25", headers=H, ssl=ctx)
            await asyncio.sleep(1.0)
            await ws.send_bytes(b"echo sb-$((40+2))\r")
            seen = b""
            t0 = time.time()
            while b"sb-42" not in seen and time.time() - t0 < 8:
                try:
                    m = await asyncio.wait_for(ws.receive(), 2)
                    if m.data and isinstance(m.data, bytes):
                        seen += m.data
                except asyncio.TimeoutError:
                    pass
            assert b"sb-42" in seen
            # a 20 KB paste arrives whole (the PTY takes ~4 KB at a time)
            await ws.send_bytes(b": " + b"x" * 20000 + b"; echo big-$((6*7))\r")
            seen, t0 = b"", time.time()
            while b"big-42" not in seen and time.time() - t0 < 10:
                try:
                    m = await asyncio.wait_for(ws.receive(), 2)
                    if m.data and isinstance(m.data, bytes):
                        seen += m.data
                except asyncio.TimeoutError:
                    pass
            assert b"big-42" in seen
            # while the phone views the chat, hooks from that pane must still count (grouped-session naming)
            r = await c.post(f"http://127.0.0.1:{cfg['hook_port']}/hook", headers={"X-Switchboard-Key": "hk"},
                             json={"_pane": pane, "hook_event_name": "UserPromptSubmit", "prompt": "hi"})
            assert "ignored" not in await r.json()
            await ws.send_str(json.dumps({"resize": [70, 20]}))
            await asyncio.sleep(0.5)
            await ws.close()
            await asyncio.sleep(0.5)
            groups = subprocess.run(["tmux", "ls", "-F", "#{session_group}"], capture_output=True, text=True).stdout
            assert groups.count(sess) <= 1  # the phone's view session is gone again, the chat is not

            # reader + fixed modes: the phone's size never resizes the real window, text and keys still flow
            size = lambda: subprocess.run(["tmux", "display", "-p", "-t", pane, "#{window_width}x#{window_height}"],
                                          capture_output=True, text=True).stdout.strip()
            before = size()
            ws = await c.ws_connect(base + f"/api/sessions/{sid}/term?mode=reader&cols=33&rows=11", headers=H, ssl=ctx)
            await asyncio.sleep(0.8)
            await ws.send_bytes(b"echo rd-$((40+3))\r")
            lines, t0 = [], time.time()
            while not any("rd-43" in ln and "echo" not in ln for ln in lines) and time.time() - t0 < 8:
                try:
                    m = await asyncio.wait_for(ws.receive(), 2)
                    if isinstance(m.data, str):
                        d = json.loads(m.data)
                        lines = lines[d["drop"]:][:d["keep"]] + d["tail"]
                        assert d["w"] == int(before.split("x")[0])
                except asyncio.TimeoutError:
                    pass
            assert any("rd-43" in ln and "echo" not in ln for ln in lines)
            await ws.send_str(json.dumps({"resize": [33, 11]}))
            await asyncio.sleep(0.4)
            assert size() == before
            await ws.close()
            ws = await c.ws_connect(base + f"/api/sessions/{sid}/term?mode=fixed&cols=33&rows=11", headers=H, ssl=ctx)
            m = await asyncio.wait_for(ws.receive(), 3)
            assert json.loads(m.data)["size"] == [int(x) for x in before.split("x")]
            await ws.close()
            assert size() == before
            await asyncio.sleep(0.5)

            # a fake permission dialog on screen + hook events -> alert -> answer by key
            subprocess.run(["tmux", "send-keys", "-t", pane, "-l",
                            "printf ' Do you want to proceed?\\n ❯ 1. Yes\\n   2. No\\n'; read -n1 k; echo GOT=$k"], check=True)
            subprocess.run(["tmux", "send-keys", "-t", pane, "Enter"], check=True)
            await asyncio.sleep(1.0)
            hook = f"http://127.0.0.1:{cfg['hook_port']}/hook"
            hh = {"X-Switchboard-Key": "hk"}
            r = await c.post(hook, json={"_pane": pane, "_kind": "claude", "hook_event_name": "PermissionRequest",
                                         "tool_name": "Bash", "tool_input": {"command": "ls"}}, headers=hh)
            aid = (await r.json())["alert"]
            assert aid
            r = await c.get(base + f"/api/alerts/{aid}", headers=H, ssl=ctx)
            a = await r.json()
            assert [o["label"] for o in a["screen_options"]] == ["Yes", "No"]
            r = await c.post(base + f"/api/alerts/{aid}/answer", json={"key": "no"}, headers=H, ssl=ctx)
            assert (await r.json())["answered"] == "No"
            await asyncio.sleep(0.8)
            screen = (await (await c.get(base + f"/api/sessions/{sid}/screen", headers=H, ssl=ctx)).json())["text"]
            assert "GOT=2" in screen
            r = await c.post(base + f"/api/alerts/{aid}/answer", json={"key": "1"}, headers=H, ssl=ctx)
            assert r.status == 409  # can't answer twice

            # a finished chat's "done" alert never presses keys, even with a dialog on screen
            r = await c.post(hook, json={"_pane": pane, "_kind": "claude", "hook_event_name": "Stop"}, headers=hh)
            done_id = (await r.json())["alert"]
            assert done_id
            r = await c.post(base + f"/api/alerts/{done_id}/answer", json={"key": "1"}, headers=H, ssl=ctx)
            assert r.status == 409
            r = await c.get(base + f"/api/sessions/{sid}/screen", params={"lines": "abc"}, headers=H, ssl=ctx)
            assert r.status == 400

            # wrong hook key / foreign pane
            r = await c.post(hook, json={"_pane": pane}, headers={"X-Switchboard-Key": "bad"})
            assert r.status == 403
            r = await c.post(base + f"/api/sessions/{sid}/rename", json={"name": "renamed"}, headers=H, ssl=ctx)
            assert r.status == 200
            r = await c.get(base + "/api/fs", params={"path": "/etc"}, headers=H, ssl=ctx)
            assert r.status == 403
            r = await c.delete(base + f"/api/sessions/{sid}", headers=H, ssl=ctx)
            assert r.status == 200
    finally:
        task.cancel()


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q", "-p", "no:cacheprovider"]))

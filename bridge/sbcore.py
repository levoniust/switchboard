"""Switchboard core: tmux control, the per-session state machine fed by Claude Code hooks, alert storage, push.

Kept free of aiohttp so it can be unit-tested on its own.
"""
import json
import os
import re
import secrets
import sqlite3
import subprocess
import threading
import time
import urllib.request

KINDS = ("claude", "claude-local", "shell")


# ---------------------------------------------------------------- config

def config_dir():
    return os.path.expanduser(os.environ.get("SWITCHBOARD_HOME", "~/.config/switchboard"))


def load_config():
    path = os.path.join(config_dir(), "config.json")
    with open(path) as f:
        cfg = json.load(f)
    cfg.setdefault("port", 8095)
    cfg.setdefault("hook_port", 8096)
    cfg.setdefault("tmux_session", "AI")
    cfg.setdefault("roots", [os.path.expanduser("~")])
    cfg.setdefault("push", {})
    cfg.setdefault("name", os.uname().nodename)
    return cfg


def new_token():
    return secrets.token_urlsafe(32)


# ---------------------------------------------------------------- tmux

class Tmux:
    """Thin wrapper over the tmux CLI. All chats are windows of one tmux session (default "AI")."""

    FMT = "#{window_id}\t#{window_index}\t#{window_name}\t#{pane_id}\t#{pane_pid}\t#{pane_current_path}\t#{pane_current_command}\t#{window_activity}\t#{pane_dead}"

    def __init__(self, session="AI", tmux="tmux"):
        self.session = session
        self.tmux = tmux

    def run(self, *args, check=True):
        r = subprocess.run([self.tmux, *args], capture_output=True, text=True, timeout=10)
        if check and r.returncode != 0:
            raise RuntimeError(f"tmux {' '.join(args)}: {r.stderr.strip()}")
        return r.stdout

    def ensure_session(self):
        if subprocess.run([self.tmux, "has-session", "-t", f"={self.session}"], capture_output=True).returncode != 0:
            self.run("new-session", "-d", "-s", self.session, "-n", "shell")

    def windows(self):
        try:
            out = self.run("list-windows", "-t", f"={self.session}", "-F", self.FMT)
        except RuntimeError:
            return []
        wins = []
        for line in out.splitlines():
            p = line.split("\t")
            if len(p) < 9:
                continue
            wins.append({"id": p[0], "index": int(p[1]), "name": p[2], "pane": p[3], "pid": int(p[4] or 0),
                         "cwd": p[5], "command": p[6], "activity": int(p[7] or 0), "dead": p[8] == "1"})
        return wins

    def pane_session(self, pane):
        """Name of the tmux session a pane belongs to ('' if unknown)."""
        r = subprocess.run([self.tmux, "display-message", "-p", "-t", pane, "#{session_name}"],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() if r.returncode == 0 else ""

    def new_window(self, name, cwd, command):
        out = self.run("new-window", "-d", "-P", "-F", "#{window_id}\t#{pane_id}", "-t", f"={self.session}:",
                       "-n", name, "-c", cwd, command)
        wid, pane = out.strip().split("\t")
        return wid, pane

    def rename(self, wid, name):
        self.run("rename-window", "-t", wid, name)

    def kill(self, wid):
        self.run("kill-window", "-t", wid)

    def send_keys(self, pane, keys=(), literal=None):
        if literal:
            self.run("send-keys", "-t", pane, "-l", literal)
        for k in keys:
            self.run("send-keys", "-t", pane, k)

    def capture(self, pane, lines=60):
        return self.run("capture-pane", "-p", "-J", "-t", pane, "-S", f"-{lines}", check=False)

    def pane_info(self, pane):
        """Size, scrollback length and full-screen (alternate screen) flag of a pane, or None if it is gone."""
        r = subprocess.run([self.tmux, "display-message", "-p", "-t", pane,
                            "#{pane_width}\t#{pane_height}\t#{history_size}\t#{alternate_on}"],
                           capture_output=True, text=True, timeout=5)
        p = r.stdout.strip().split("\t")
        if r.returncode != 0 or len(p) < 4:
            return None
        return {"w": int(p[0]), "h": int(p[1]), "hist": int(p[2]), "alt": p[3] == "1"}

    def snapshot(self, pane, lines=2000):
        """Scrollback + screen with colours (SGR escapes), wrapped lines joined, as a list of lines."""
        out = self.run("capture-pane", "-p", "-e", "-J", "-t", pane, "-S", f"-{lines}", check=False)
        rows = out.split("\n")
        if rows and rows[-1] == "":
            rows.pop()
        while rows and not rows[-1].strip():
            rows.pop()
        return rows

    def view_session(self, wid):
        """A grouped session that shares the windows but has its own current window, so the phone
        can look at one chat while the Surface looks at another."""
        name = "sbv-" + secrets.token_hex(4)
        self.run("new-session", "-d", "-s", name, "-t", f"={self.session}")
        self.run("set-option", "-t", name, "status", "off")
        self.run("select-window", "-t", f"{name}:{wid}")
        return name

    def cleanup_views(self):
        """Remove phone view sessions left over from a crash."""
        out = self.run("list-sessions", "-F", "#{session_name}", check=False)
        for name in out.split():
            if name.startswith("sbv-"):
                self.kill_session(name)

    def kill_session(self, name):
        self.run("kill-session", "-t", f"={name}", check=False)


def command_for(kind):
    """Shell command a new chat window runs. Falls back to a shell when the program exits."""
    if kind == "claude":
        return "bash -ic 'claude; exec bash'"
    if kind == "claude-local":
        return "bash -ic 'claude-local; exec bash'"
    return "bash -l"


def detect_kind(pid):
    """claude / claude-local / shell from the pane's process tree (env of the claude process)."""
    for p in _descendants(pid):
        try:
            cmd = open(f"/proc/{p}/cmdline", "rb").read().split(b"\0")
        except OSError:
            continue
        if any(os.path.basename(c) == b"claude" or c.endswith(b"/claude") for c in cmd[:2]):
            try:
                env = open(f"/proc/{p}/environ", "rb").read().split(b"\0")
            except OSError:
                env = []
            base = next((e for e in env if e.startswith(b"ANTHROPIC_BASE_URL=")), b"")
            return "claude-local" if base and b"anthropic.com" not in base else "claude"
    return "shell"


def _descendants(pid, depth=4):
    out, level = [], [pid]
    for _ in range(depth):
        nxt = []
        for p in level:
            try:
                with open(f"/proc/{p}/task/{p}/children") as f:
                    nxt += [int(x) for x in f.read().split()]
            except OSError:
                pass
        out += nxt
        level = nxt
    return out


# ---------------------------------------------------------------- dialogs on screen

OPTION_RE = re.compile(r"^\s*(?:❯\s*)?(\d)\.\s+(.+?)\s*$")


def screen_diff(prev, new, scrolled=0):
    """Smallest update that turns the phone's copy of the screen (prev) into new.
    scrolled = how many lines left the top since prev (scrollback growth). The phone applies
    lines = lines[drop:][:keep] + tail. Falls back to a full send when the guess doesn't line up."""
    if prev is None:
        return {"drop": 0, "keep": 0, "tail": new, "full": True}
    drop = scrolled if 0 <= scrolled <= len(prev) else len(prev)
    base = prev[drop:]
    keep = 0
    for a, b in zip(base, new):
        if a != b:
            break
        keep += 1
    return {"drop": drop, "keep": keep, "tail": new[keep:], "full": keep == 0 and drop == len(prev)}


def parse_options(screen):
    """Numbered choices of the dialog at the bottom of a captured Claude Code screen: [(digit, label)].
    Takes the last "1." line in the bottom 40 lines and the 2., 3., ... lines that follow it."""
    lines = [l for l in screen.splitlines() if l.strip()][-40:]
    found = [(i, m.group(1), m.group(2)) for i, l in enumerate(lines) if (m := OPTION_RE.match(l))]
    starts = [k for k, (_, d, _) in enumerate(found) if d == "1"]
    if not starts:
        return []
    opts, want = [], 1
    for _, d, label in found[starts[-1]:]:
        if d == str(want):
            opts.append((d, label))
            want += 1
    return opts


# ---------------------------------------------------------------- alerts store

class Store:
    def __init__(self, path):
        self.lock = threading.Lock()
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.execute("""CREATE TABLE IF NOT EXISTS alerts(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, pane TEXT, window TEXT, session_name TEXT, kind TEXT,
            type TEXT, title TEXT, body TEXT, options TEXT, state TEXT DEFAULT 'open', answered TEXT)""")
        self.db.commit()

    def add(self, **a):
        with self.lock:
            cur = self.db.execute(
                "INSERT INTO alerts(ts,pane,window,session_name,kind,type,title,body,options) VALUES(?,?,?,?,?,?,?,?,?)",
                (time.time(), a.get("pane"), a.get("window"), a.get("session_name"), a.get("kind"), a["type"],
                 a["title"], a.get("body", ""), json.dumps(a.get("options") or [])))
            self.db.commit()
            return cur.lastrowid

    def close(self, alert_id, state="closed", answered=None):
        with self.lock:
            self.db.execute("UPDATE alerts SET state=?, answered=? WHERE id=? AND state='open'", (state, answered, alert_id))
            self.db.commit()

    def close_pane(self, pane, state="closed"):
        with self.lock:
            self.db.execute("UPDATE alerts SET state=? WHERE pane=? AND state='open' AND type IN ('permission','question')",
                            (state, pane))
            self.db.commit()

    def get(self, alert_id):
        rows = self.list(where="id=?", args=(alert_id,), limit=1)
        return rows[0] if rows else None

    def list(self, where="1=1", args=(), limit=200):
        with self.lock:
            cur = self.db.execute(f"SELECT id,ts,pane,window,session_name,kind,type,title,body,options,state,answered "
                                  f"FROM alerts WHERE {where} ORDER BY id DESC LIMIT ?", (*args, limit))
            cols = [c[0] for c in cur.description]
            rows = [dict(zip(cols, r)) for r in cur.fetchall()]
        for r in rows:
            r["options"] = json.loads(r["options"] or "[]")
        return rows

    def prune(self, keep_days=30):
        with self.lock:
            self.db.execute("DELETE FROM alerts WHERE ts < ?", (time.time() - keep_days * 86400,))
            self.db.commit()


# ---------------------------------------------------------------- state machine

def short(text, n=300):
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[: n - 1] + "…"


def describe_tool(name, inp):
    inp = inp or {}
    if name == "Bash":
        return inp.get("description") or "Run a command", inp.get("command", "")
    if name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        return f"{name} a file", inp.get("file_path") or inp.get("notebook_path", "")
    if name in ("WebFetch",):
        return "Fetch a web page", inp.get("url", "")
    return f"Use {name}", short(json.dumps(inp), 200)


class Sessions:
    """Live status per tmux pane, driven by hook events. Emits alerts through on_alert(alert_dict)."""

    def __init__(self, store, on_alert=None, on_change=None):
        self.store = store
        self.on_alert = on_alert or (lambda a: None)
        self.on_change = on_change or (lambda pane, st: None)
        self.state = {}  # pane -> dict(status, kind, model, session_id, pending alert id, updated, last)

    def get(self, pane):
        return self.state.setdefault(pane, {"status": "idle", "kind": None, "model": None, "pending": None,
                                            "updated": time.time(), "last": ""})

    def _set(self, pane, **kw):
        st = self.get(pane)
        st.update(kw, updated=time.time())
        self.on_change(pane, st)
        return st

    def hook(self, ev, meta):
        """ev = raw hook JSON from Claude Code; meta = {pane, window, session_name, kind, title} filled in by the server."""
        pane = meta.get("pane") or ""
        name = ev.get("hook_event_name", "")
        if not pane:
            return None
        st = self.get(pane)
        if ev.get("model"):
            st["model"] = ev["model"]
        if meta.get("kind"):
            st["kind"] = meta["kind"]
        base = {"pane": pane, "window": meta.get("window"), "session_name": meta.get("title"), "kind": st.get("kind")}

        if name == "SessionStart":
            self._set(pane, status="idle", session_id=ev.get("session_id"))
        elif name == "UserPromptSubmit":
            self._clear_pending(pane)
            self._set(pane, status="working", last=short(ev.get("prompt"), 120))
        elif name == "PreToolUse":
            if ev.get("tool_name") != "AskUserQuestion" and not st.get("pending"):
                self._set(pane, status="working")
        elif name == "PermissionRequest":
            if st.get("pending"):
                return None
            if ev.get("tool_name") == "AskUserQuestion":
                qs = (ev.get("tool_input") or {}).get("questions") or []
                q = qs[0] if qs else {}
                opts = [{"key": str(i + 1), "label": o.get("label", ""), "detail": o.get("description", "")}
                        for i, o in enumerate(q.get("options") or [])]
                extra = len(qs) - 1
                body = q.get("question", "") + (f"  (+{extra} more question{'s' if extra > 1 else ''})" if extra > 0 else "")
                return self._alert(pane, "question", q.get("header") or "Question", body, opts, base, questions=qs)
            what, detail = describe_tool(ev.get("tool_name"), ev.get("tool_input"))
            return self._alert(pane, "permission", what, short(detail, 400), None, base)
        elif name == "Notification":
            nt = ev.get("notification_type")
            if nt == "permission_prompt" and not st.get("pending"):
                return self._alert(pane, "permission", "Needs your permission", ev.get("message", ""), None, base)
            if nt == "idle_prompt":
                self._set(pane, status="waiting")
        elif name == "PostToolUse":
            if st.get("pending"):
                self._clear_pending(pane, state="answered")
            self._set(pane, status="working")
        elif name == "Stop":
            self._clear_pending(pane)
            msg = ev.get("last_assistant_message") or "Finished."
            self._set(pane, status="done")
            return self._alert(pane, "done", "Done", short(msg, 600), None, base, pending=False)
        elif name == "SessionEnd":
            self._clear_pending(pane)
            self._set(pane, status="ended")
        return None

    def _alert(self, pane, typ, title, body, options, base, pending=True, questions=None):
        aid = self.store.add(type=typ, title=title, body=body, options=options, **base)
        alert = self.store.get(aid)
        if questions:
            alert["questions"] = questions
        if pending:
            self._set(pane, status=typ, pending=aid)
        self.on_alert(alert)
        return alert

    def _clear_pending(self, pane, state="closed"):
        st = self.get(pane)
        if st.get("pending"):
            self.store.close(st["pending"], state=state)
        self.store.close_pane(pane, state=state)
        st["pending"] = None

    def answered(self, pane, alert_id, answer):
        self.store.close(alert_id, state="answered", answered=answer)
        st = self.get(pane)
        if st.get("pending") == alert_id:
            st["pending"] = None
        self._set(pane, status="working")


# ---------------------------------------------------------------- push (Home Assistant companion app)

def ha_push(cfg_push, alert, link_base="switchboard://"):
    """Send an alert to the phone through HA's mobile_app notify service. Tapping opens the app at the alert."""
    url, service = cfg_push.get("ha_url"), cfg_push.get("ha_notify")
    if not (cfg_push.get("enabled") and url and service):
        return False
    token = open(os.path.expanduser(cfg_push.get("ha_token_file", "~/.ha_token"))).read().strip()
    icon = {"permission": "🔐", "question": "❓", "done": "✅", "error": "⚠️"}.get(alert["type"], "🔔")
    who = alert.get("session_name") or alert.get("window") or "Claude"
    open_link = f"{link_base}alert/{alert['id']}"
    data = {"clickAction": open_link, "url": open_link, "tag": f"sb-{alert.get('pane')}", "group": "switchboard",
            "channel": "Switchboard " + ("Done" if alert["type"] == "done" else "Needs you"),
            "importance": "high", "priority": "high", "ttl": 0, "notification_icon": "mdi:console"}
    opts = alert.get("options") or []
    if alert["type"] == "permission":
        opts = [{"key": "1", "label": "Yes"}, {"key": "no", "label": "No"}]
    if opts:
        data["actions"] = [{"action": "URI", "title": o["label"][:20],
                            "uri": f"{link_base}answer/{alert['id']}/{o['key']}"} for o in opts[:3]]
    body = {"title": f"{icon} {who}: {alert['title']}", "message": alert.get("body") or alert["title"], "data": data}
    req = urllib.request.Request(f"{url.rstrip('/')}/api/services/notify/{service}", json.dumps(body).encode(),
                                 {"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status < 300

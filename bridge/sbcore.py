"""Switchboard core: tmux control, the per-session state machine fed by Claude Code hooks, alert storage, push.

Kept free of aiohttp so it can be unit-tested on its own.
"""
import hashlib
import json
import os
import platform
import re
import secrets
import sqlite3
import subprocess
import threading
import time
import urllib.request

KINDS = ("claude", "claude-local", "shell")  # the built-in launchers (old apps only know these)

# What the app's "new chat" menu offers. Override with "launchers" in config.json, e.g. to name your local model or
# add a second local agent. Fields: kind (id), label (badge text), name (default window name), command (program to
# run in the window), claude (true = Claude Code, gets hooks/Reader support), accent (1 or 2 = skin colour),
# icon (cloud|chip|terminal|spark), match (env vars of the running claude process that identify this launcher).
DEFAULT_LAUNCHERS = [
    {"kind": "claude", "label": "Claude", "name": "claude", "command": "claude", "claude": True, "accent": 1,
     "icon": "cloud"},
    {"kind": "claude-local", "label": "Local", "name": "local", "command": "claude-local", "claude": True,
     "accent": 2, "icon": "chip"},
    {"kind": "shell", "label": "Shell", "name": "shell", "command": "", "claude": False, "accent": 1,
     "icon": "terminal"},
]
_KIND_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
_CMD_RE = re.compile(r"^[A-Za-z0-9_./ -]*$")
_WIN_CMD_RE = re.compile(r"^[A-Za-z0-9_./\\: -]*$")  # Windows paths: C:\dir\x.ps1


def launchers(cfg, cmd_re=None):
    """The launcher list from config.json (validated) or the defaults. The shell launcher is always there.
    cmd_re: what a command may contain (Windows nodes also allow \\ and : for paths)."""
    out = []
    cmd_re = cmd_re or (_WIN_CMD_RE if IS_WINDOWS else _CMD_RE)
    for item in cfg.get("launchers") or DEFAULT_LAUNCHERS:
        kind, command = str(item.get("kind", "")), str(item.get("command", ""))
        if not _KIND_RE.match(kind) or not cmd_re.match(command) or any(l["kind"] == kind for l in out):
            continue  # commands go inside bash -ic '...': keep them to plain words so nothing can break out
        out.append({"kind": kind, "label": str(item.get("label") or kind)[:16], "name": str(item.get("name") or kind)[:40],
                    "command": command, "claude": bool(item.get("claude", kind != "shell")),
                    "accent": 2 if item.get("accent") == 2 else 1, "icon": str(item.get("icon") or "chip")[:16],
                    "match": {str(k): str(v) for k, v in (item.get("match") or {}).items()}})
    if not any(l["kind"] == "shell" for l in out):
        out.append(dict(DEFAULT_LAUNCHERS[-1], match={}))
    return out


def public_launchers(cfg):
    return [{k: l[k] for k in ("kind", "label", "name", "claude", "accent", "icon")} for l in launchers(cfg)]


# ---------------------------------------------------------------- config

IS_WINDOWS = os.name == "nt"
PROTO = 2  # docs/NETWORK-PROTOCOL.md


def config_dir():
    default = os.path.join(os.environ.get("LOCALAPPDATA", "~"), "switchboard") if IS_WINDOWS else "~/.config/switchboard"
    return os.path.expanduser(os.environ.get("SWITCHBOARD_HOME", default))


def os_name():
    return "windows" if IS_WINDOWS else "linux"


def ensure_node_id(cfg, path=None):
    """Every node has a random id that never changes (the app keys chats and alerts by it). Created on first use and
    written back to config.json."""
    if cfg.get("node_id"):
        return cfg["node_id"]
    cfg["node_id"] = secrets.token_hex(8)
    path = path or os.path.join(config_dir(), "config.json")
    try:
        with open(path) as f:
            disk = json.load(f)
        disk["node_id"] = cfg["node_id"]
        write_private_json(path, disk)
    except OSError:
        pass  # no config file (tests): the id lives for this run only
    return cfg["node_id"]


def write_private_json(path, data):
    """Write JSON readable only by the owner (atomic replace)."""
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def make_cert(cert_path, key_path, hosts, name, days=3650):
    """Self-signed EC P-256 certificate for the node's addresses (the app pins its SHA-256, so no CA is involved).
    Uses the cryptography package so it works on Windows too (no openssl binary needed)."""
    import datetime
    import ipaddress
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID

    key = ec.generate_private_key(ec.SECP256R1())
    sans = []
    for h in list(hosts) + ["127.0.0.1"]:
        try:
            sans.append(x509.IPAddress(ipaddress.ip_address(h)))
        except ValueError:
            sans.append(x509.DNSName(h))
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"switchboard-{name}")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=days))
            .add_extension(x509.SubjectAlternativeName(list(dict.fromkeys(sans))), critical=False)
            .sign(key, hashes.SHA256()))
    fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                  serialization.NoEncryption()))
    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))


def load_config():
    path = os.path.join(config_dir(), "config.json")
    with open(path) as f:
        cfg = json.load(f)
    cfg.setdefault("port", 8095)
    cfg.setdefault("hook_port", 8096)
    cfg.setdefault("tmux_session", "AI")
    cfg.setdefault("roots", [os.path.expanduser("~")])
    cfg.setdefault("push", {})
    cfg.setdefault("name", platform.node())
    cfg.setdefault("legacy_token", True)
    return cfg


def new_token():
    return secrets.token_urlsafe(32)


# ---------------------------------------------------------------- devices + pairing (proto 2)

def _hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


class Devices:
    """Paired devices (phones, desktop apps), each with its own token. Only sha256(token) is stored, in devices.json.
    One-time pairing codes live in pair-codes.json, because `switchboard pair` runs as a separate process."""

    CODE_TTL = 600

    def __init__(self, home):
        self.path = os.path.join(home, "devices.json")
        self.codes_path = os.path.join(home, "pair-codes.json")
        self.lock = threading.Lock()

    def _load(self, path):
        try:
            with open(path) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def all(self):
        return self._load(self.path)

    def list(self):
        return [{"id": k, "name": v.get("name", ""), "created": v.get("created"), "last_seen": v.get("last_seen")}
                for k, v in self.all().items()]

    def new_code(self):
        code = secrets.token_urlsafe(12)
        with self.lock:
            codes = {k: v for k, v in self._load(self.codes_path).items() if v > time.time()}
            codes[_hash(code)] = time.time() + self.CODE_TTL
            write_private_json(self.codes_path, codes)
        return code

    def redeem(self, code, name):
        """Turns a valid one-time code into a new device. Returns (device_id, token) or None."""
        with self.lock:
            codes = self._load(self.codes_path)
            exp = codes.pop(_hash(code or ""), None)
            write_private_json(self.codes_path, {k: v for k, v in codes.items() if v > time.time()})
            if not exp or exp < time.time():
                return None
            devs = self.all()
            dev_id, token = secrets.token_hex(6), new_token()
            devs[dev_id] = {"name": (name or "device")[:40], "hash": _hash(token), "created": time.time(),
                            "last_seen": time.time()}
            write_private_json(self.path, devs)
        return dev_id, token

    def check(self, token):
        """Device id for a token, or None. Constant-time compare against every stored hash."""
        if not token:
            return None
        h, found = _hash(token).encode(), None
        devs = self.all()
        for dev_id, d in devs.items():
            if secrets.compare_digest(h, d.get("hash", "").encode()):
                found = dev_id
        if found and time.time() - (devs[found].get("last_seen") or 0) > 60:
            with self.lock:
                devs = self.all()
                if found in devs:
                    devs[found]["last_seen"] = time.time()
                    write_private_json(self.path, devs)
        return found

    def revoke(self, dev_id):
        with self.lock:
            devs = self.all()
            if devs.pop(dev_id, None) is None:
                return False
            write_private_json(self.path, devs)
        return True


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
        # the default 2000-line scrollback is far too small for "scroll the whole chat". tmux only
        # applies history-limit to windows created after the session option is set (verified 3.5a:
        # setting it on an existing window leaves its history at the old size), so set it first.
        self.run("set-window-option", "-t", f"={self.session}", "history-limit", "50000", check=False)
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


def command_for(kind, cfg=None):
    """Shell command a new chat window runs. Falls back to a shell when the program exits.
    Claude runs with the alternate screen disabled so its output scrolls into tmux history
    and the app's Reader can scroll back through the whole conversation."""
    l = next((l for l in launchers(cfg or {}) if l["kind"] == kind), None)
    if not l or not l["command"]:
        return "bash -l"
    env = "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 " if l["claude"] else ""
    return f"bash -ic '{env}{l['command']}; exec bash'"


def detect_kind(pid, cfg=None):
    """Launcher kind from the pane's process tree: a launcher whose "match" env vars all equal the running
    claude process's environment wins; otherwise claude (Anthropic API) / claude-local (any other base URL)."""
    for p in _descendants(pid):
        try:
            cmd = open(f"/proc/{p}/cmdline", "rb").read().split(b"\0")
        except OSError:
            continue
        if any(os.path.basename(c) == b"claude" or c.endswith(b"/claude") for c in cmd[:2]):
            try:
                raw = open(f"/proc/{p}/environ", "rb").read().split(b"\0")
            except OSError:
                raw = []
            env = dict(e.decode("utf-8", "replace").split("=", 1) for e in raw if b"=" in e)
            return kind_from_env(env, cfg)
    return "shell"


def kind_from_env(env, cfg):
    """A launcher whose "match" env vars all equal the claude process's environment wins; otherwise the first
    claude launcher for the API it talks to (Anthropic = "claude", anything else = the first local claude launcher
    without a "match", e.g. a Windows node's only local launcher)."""
    ls = launchers(cfg or {})
    for l in ls:
        if l["match"] and all(env.get(k) == v for k, v in l["match"].items()):
            return l["kind"]
    base = env.get("ANTHROPIC_BASE_URL", "")
    local = bool(base) and "anthropic.com" not in base
    if not local:
        return "claude"
    return next((l["kind"] for l in ls if l["claude"] and l["kind"] != "claude" and not l["match"]), "claude-local")


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


# proto=2 (Reader deep history): seed the phone with the whole scrollback, then keep it in sync
# with window diffs. DEEP = how many lines the seed captures, FULL_CAP = what the phone keeps.
DEEP_CAPTURE = 40000
FULL_CAP = 60000


def full_keep_len(full_len, prev_len, d):
    """proto=2: a window diff d was computed against a window of prev_len lines that sits at the
    tail of the phone's full list of full_len lines. Returns how many head lines of the full list
    survive: lines = lines[:keep_len] + d['tail'] (then [trim:] if the caller trims the cap)."""
    return full_len - (prev_len - d["drop"] - d["keep"])


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

APP_PACKAGE = "dev.levoniust.switchboard"


def app_link(path, node=None):
    """Tap link for HA companion notifications. The Android HA app doesn't hand custom schemes to other apps: a bare
    switchboard://x is loaded as a page inside HA (404). An intent: URI is passed to Android, which opens Switchboard."""
    if node:
        path += f"?node={node}"
    return f"intent://{path}#Intent;scheme=switchboard;package={APP_PACKAGE};end"


def ha_push(cfg_push, alert, link=app_link, node=None):
    """Send an alert to the phone through HA's mobile_app notify service. Tapping opens the app at the alert."""
    url, service = cfg_push.get("ha_url"), cfg_push.get("ha_notify")
    if not (cfg_push.get("enabled") and url and service):
        return False
    token = open(os.path.expanduser(cfg_push.get("ha_token_file", "~/.ha_token"))).read().strip()
    icon = {"permission": "🔐", "question": "❓", "done": "✅", "error": "⚠️"}.get(alert["type"], "🔔")
    who = alert.get("session_name") or alert.get("window") or "Claude"
    q = f"?node={node}" if node else ""
    data = {"clickAction": link(f"alert/{alert['id']}", node), "url": f"switchboard://alert/{alert['id']}{q}", "tag": f"sb-{node + '-' if node else ''}{alert.get('pane')}", "group": "switchboard",
            "channel": "Switchboard " + ("Done" if alert["type"] == "done" else "Needs you"),
            "importance": "high", "priority": "high", "ttl": 0, "notification_icon": "mdi:console"}
    opts = alert.get("options") or []
    if alert["type"] == "permission":
        opts = [{"key": "1", "label": "Yes"}, {"key": "no", "label": "No"}]
    if opts:
        data["actions"] = [{"action": "URI", "title": o["label"][:20],
                            "uri": link(f"answer/{alert['id']}/{o['key']}", node)} for o in opts[:3]]
    body = {"title": f"{icon} {who}: {alert['title']}", "message": alert.get("body") or alert["title"], "data": data}
    req = urllib.request.Request(f"{url.rstrip('/')}/api/services/notify/{service}", json.dumps(body).encode(),
                                 {"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status < 300

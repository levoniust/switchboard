#!/usr/bin/env bash
# Switchboard bridge installer (Linux, user level, no root needed except optional linger).
#
#   deploy/install.sh [--hosts 192.168.1.10,100.x.y.z] [--ha-url URL --ha-notify mobile_app_phone] [--vigil-url URL] [--no-hooks]
#
# - copies the bridge to ~/.local/share/switchboard and the hook to ~/.local/bin/switchboard-hook
# - creates ~/.config/switchboard (token, TLS cert, config) via `switchboard.py init`
# - adds the status hooks to ~/.claude/settings.json (backup first; existing hooks are kept)
# - installs + starts the systemd --user service `switchboard`
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
dest=$HOME/.local/share/switchboard
uv=$(command -v uv || echo "$HOME/.local/bin/uv")
[ -x "$uv" ] || { echo "Switchboard needs uv (https://docs.astral.sh/uv/)"; exit 1; }
command -v tmux >/dev/null || { echo "Switchboard needs tmux"; exit 1; }

hooks=1; init_args=()
while [ $# -gt 0 ]; do
  case $1 in
    --no-hooks) hooks=0 ;;
    --hosts|--ha-url|--ha-notify|--ha-token-file|--vigil-url|--port|--tmux-session)
      [ $# -ge 2 ] || { echo "$1 needs a value"; exit 1; }
      init_args+=("$1" "$2"); shift ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac; shift
done

mkdir -p "$dest" "$HOME/.local/bin" "$HOME/.config/systemd/user"
cp "$here"/bridge/switchboard.py "$here"/bridge/sbcore.py "$dest"/
install -m 755 "$here"/hooks/switchboard-hook "$HOME/.local/bin/switchboard-hook"
cat > "$HOME/.local/bin/switchboard" <<EOF
#!/usr/bin/env bash
exec "$uv" run -q --script "$dest/switchboard.py" "\$@"
EOF
chmod 755 "$HOME/.local/bin/switchboard"
"$HOME/.local/bin/switchboard" init "${init_args[@]}"

if [ $hooks -eq 1 ]; then
  settings=$HOME/.claude/settings.json
  mkdir -p "$HOME/.claude"; [ -f "$settings" ] || echo '{}' > "$settings"
  cp "$settings" "$settings.bak-switchboard-$(date +%Y%m%d-%H%M%S)"
  python3 - "$settings" "$HOME/.local/bin/switchboard-hook" <<'PY'
import json, sys
path, hook = sys.argv[1], sys.argv[2]
s = json.load(open(path))
hooks = s.setdefault("hooks", {})
entry = {"type": "command", "command": hook, "timeout": 5}
for ev in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Notification", "Stop", "SessionEnd"]:
    groups = hooks.setdefault(ev, [])
    if any(h.get("command") == hook for g in groups for h in g.get("hooks", [])):
        continue
    g = {"hooks": [entry]}
    if ev in ("PreToolUse", "PermissionRequest", "PostToolUse"):
        g["matcher"] = "*"
    groups.append(g)
json.dump(s, open(path, "w"), indent=2)
print("hooks added to", path)
PY
fi

cat > "$HOME/.config/systemd/user/switchboard.service" <<EOF
[Unit]
Description=Switchboard bridge (phone access to Claude Code chats in tmux)
After=network-online.target

[Service]
ExecStart=$uv run -q --script $dest/switchboard.py serve
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now switchboard
systemctl --user restart switchboard
loginctl show-user "$USER" -p Linger | grep -q yes || echo "Tip: 'sudo loginctl enable-linger $USER' keeps the bridge running after you log out."
echo "Done. Pair a phone: switchboard pair   (or: switchboard download-link)"

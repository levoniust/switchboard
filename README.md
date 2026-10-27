# Switchboard

**A phone switchboard for Claude Code.** An Android app plus a small bridge on your Linux box that let you drive
[Claude Code](https://claude.com/claude-code) chats from your phone. It works with the normal cloud `claude` and with
Claude Code pointed at a local model (`claude-local`, e.g. Qwen through llama.cpp). Chats live in **tmux**, so they
survive dropped connections. The phone gets **alerts** when a chat is done, needs permission or has a question, and
tapping one opens the app at that prompt with the answer buttons ready.

```
Phone (Flutter app) ──WSS, pinned self-signed TLS, token──► switchboard bridge (Python, systemd --user)
   LAN at home / Tailscale away (auto)                        ├─ tmux session "AI": one window per chat
                                                              ├─ Claude Code hooks → status + alerts
                                                              ├─ Home Assistant push (optional) → deep links
                                                              └─ optional reverse proxy for another LAN page (e.g. a dashboard)
```

## What it does

- **It's still a CLI.** A real terminal (xterm) attached to the chat's tmux window, full colour, and the window
  resizes to the phone every time you open it. A quick-key bar (Esc, Tab, Shift-Tab for modes, arrows, Ctrl-C, 1/2/3, …),
  a multi-line **composer** (sent as one paste, keyboard voice input works), a **slash-command palette**, and
  **photo upload**: the picture lands on the server and its path goes into your message.
- **Answer prompts with one tap.** When Claude asks for permission or uses its multiple-choice question tool, the
  bridge reads the real choices off the screen ("Yes / Yes, and always allow … / No") and shows them as buttons, on the
  chat list, in the chat, and in the alert. Tapping presses the matching number in the chat.
- **Persistent chats.** Everything runs in tmux on the server. Close the app, lose signal or switch networks, and the
  chat keeps going; reopen it and you're back. The same windows are there when you `tmux attach` from a laptop.
  Phones attach through their own grouped view session, so the laptop's current window doesn't jump around.
- **Alerts.** Claude Code hooks (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`,
  `PostToolUse`, `Notification`, `Stop`, `SessionEnd`) feed a small state machine: working → needs permission /
  question → done. While the app is open you get an in-app banner. When it's closed, the bridge pushes through the
  **Home Assistant companion app** (Firebase delivery, so you don't need to exempt Switchboard from battery
  optimisation). Tapping the notification opens `switchboard://alert/<id>`, and its buttons answer directly
  (`switchboard://answer/<id>/<choice>`).
- **New chats from the phone:** pick `claude`, `claude-local` or a shell, and a folder.
- **Skins.** *Terminal* (green phosphor, default), *Material 1* (2014 paper and shadows), *Starship* (a bridge
  console with elbows and pills), *Galactic* (hologram blue and crawl yellow), *Neon Night* (cyberpunk), *Amber CRT*.
  All are drawn in code with open-licensed fonts (OFL). **Mascot packs:** drop your own pictures and lines into
  `app/assets/private/miko/` and three more skins appear (see below). That folder is git-ignored.

## Security model

- The bridge listens **only** on the addresses you give it (e.g. the LAN IP and the Tailscale IP), never `0.0.0.0`.
  Put it behind your LAN and/or Tailscale. **Do not port-forward it to the internet.** It is a shell on your machine.
- TLS uses a self-signed certificate. The app **pins its SHA-256** (from the pairing link), so it trusts nothing else.
- One random access token (`~/.config/switchboard/config.json`, mode 600). The pairing link contains it: treat it like a password.
- Hooks talk to the bridge on `127.0.0.1` with a separate key. They only report status: they never block or change what Claude does.
- New chats can only start in folders under `roots` (default: your home directory).

## Install the bridge (Linux)

Needs `tmux`, [`uv`](https://docs.astral.sh/uv/), `openssl`, Claude Code, and systemd user services.

```bash
git clone <this repo> && cd switchboard
deploy/install.sh --hosts 192.168.1.10,100.x.y.z          # your LAN IP, your Tailscale IP
# optional phone push via Home Assistant (token in ~/.ha_token):
#   --ha-url http://homeassistant.local:8123 --ha-notify mobile_app_my_phone
# optional page to show in the app's web tab:  --vigil-url http://192.168.1.20:30300
sudo loginctl enable-linger $USER                          # keep it running after you log out
switchboard pair                                           # pairing link + QR code
```

`switchboard download-link` prints a one-time page (48 h) that offers the APK (copy a build to
`~/.config/switchboard/switchboard.apk`) and the pairing link. `switchboard push on|off|test` controls phone push.

A `claude-local` chat runs `bash -ic 'claude-local'`, so define `claude-local` as a shell function or alias, e.g. one
that sets `ANTHROPIC_BASE_URL` to your local server and starts `claude`.

## Build the app

Flutter 3.4x, Android SDK, JDK 17.

```bash
cd app
flutter test && flutter analyze
flutter build apk --release --split-per-abi      # signs with android/key.properties if present, else the debug key
```

Install the APK, open the pairing link on the phone (or paste it into the app), done. The app tries the hosts in
order (LAN first) and switches to Tailscale automatically when you're away.

**Samsung / Android tips:** allow notifications for the Home Assistant app. Switchboard itself doesn't need to stay
awake, because push comes through Home Assistant.

## Mascot packs (optional, private)

Put `pro_<state>.webp`, `hood_<state>.webp` and `chibi_<state>.webp` (states: idle, working, done, permission,
question, error, sleep; 384×384 works well) plus a `lines.json`
(`{"pro": {"done": ["{session} is done."], ...}, "afterhours": {...}, "chibi": {...}}`) into
`app/assets/private/miko/` and rebuild. The three mascot skins only show up when the pictures are present.

## Tests

- Bridge: `cd bridge && uv run --script test_bridge.py`. Unit tests (dialog parsing, state machine, push payload)
  plus an end-to-end test against a throwaway tmux session (terminal over WebSocket, hook → alert → answer by key).
- App: `cd app && flutter test`.

## License

MIT (see LICENSE). Fonts under the SIL Open Font License (`app/assets/fonts/licenses/`).
Not affiliated with Anthropic. "Claude" and "Claude Code" are Anthropic's names, used to say what this works with.

# Switchboard network protocol (proto 2)

Status: design for 1.3.0. Switchboard grows from "one app ↔ one bridge" to "one app ↔ many machines".
Every machine runs its own **node** (the bridge) that works on its own. There is no hub: the app talks to
each node directly (LAN address first, then Tailscale) and merges what it sees.

## Goals
- Any number of machines, Linux and Windows, each a standalone node. A node being down affects only its own chats.
- Same features on every node: chat list, Reader view with full scrollback, raw terminal, answering prompts,
  push alerts, new chat from a launcher, files/upload.
- Each device (phone, desktop app) pairs with each node and gets **its own key**, so one device can be revoked
  without re-pairing the others.
- Old apps keep working against new nodes (legacy shared token, until the owner turns it off).

## Node identity
`config.json` gains:

| key | meaning |
|---|---|
| `node_id` | random 16-hex id, created once by `init`/first `serve`. Never changes. |
| `name` | display name (default: host name) |
| `legacy_token` | `true` (default) = the old shared `token` still works. `switchboard devices legacy off` turns it off. |

`GET /api/info` adds `node_id`, `os` (`linux`/`windows`), `proto: 2` and `features` (list of strings, e.g.
`["pair2", "devices", "reader2", "upload", "fs", "vigil"]`). The app decides what to show from `features`,
not from the version number.

## Pairing (per device, QR or link)
1. On the machine: `switchboard pair` makes a **one-time pairing code** (valid 10 minutes, single use) and prints
   a QR code and the link
   `switchboard://pair/<base64url(json)>` with json
   `{"v":2, "id":node_id, "n":name, "h":[hosts], "p":port, "c":cert_sha256, "k":code}`.
   The link holds no long-lived secret.
2. The app (scan QR, or paste/tap the link) pins the certificate, then calls
   `POST /api/pair {"code": k, "device": "<device name>"}` (no auth needed; a wrong code costs a 2 s delay, and
   5 wrong codes in 10 minutes lock pairing for 10 minutes).
3. The node answers `{"device_id", "token", "node_id", "name"}`. It stores only `sha256(token)` in `devices.json`
   (`{device_id: {name, hash, created, last_seen}}`, mode 600).
4. The app stores the node (`id, name, hosts, port, pin, token`) in its node list.

Version-1 links (`{"v":1, ... "t":token}`) still work: the app saves the node with the shared token.

### Devices
- `GET /api/devices` → list (no hashes); `DELETE /api/devices/{id}` revokes (a device can revoke itself = "forget").
- CLI: `switchboard devices` (list), `switchboard devices revoke ID`, `switchboard devices legacy on|off`.
- Auth: `Authorization: Bearer <token>` matches a device hash (constant-time) or, while `legacy_token` is on, the
  shared token. `last_seen` updates at most once a minute.

## App ↔ node API
Unchanged from proto 1 (sessions, keys, screen, term `?mode=live|fixed|reader&proto=2`, alerts, answer, fs, upload,
events, vigil). The app keeps one events socket **per node**. Rules for many nodes:
- Ids (window, pane, alert) are only unique **within a node**. The app keys everything by `(node_id, id)`.
- Focus: when the app is in the foreground it sends `*` to every node; when a chat is open it sends that chat's
  pane to its node and `*` to the others; desktop window in the background sends `-` to all.
- Push links carry the node: `switchboard://alert/<id>?node=<node_id>`, `answer/<id>/<key>?node=…`,
  `session/<pane>?node=…`. A link without `node` means the first node in the app's list (old pushes).
- Vigil: the app uses the first node whose `/api/info` says `vigil: true`.

## Windows nodes
The node is the same Python program (`bridge/switchboard.py` + `sbcore.py`). Only the terminal backend differs:

| | Linux | Windows |
|---|---|---|
| Chats live in | tmux session `AI` | **sbkeeper**: a small long-lived process holding ConPTY sessions (pywinpty) |
| Screen + scrollback | `tmux capture-pane` | pyte `HistoryScreen` (50 000 lines) kept by sbkeeper |
| Raw terminal | `tmux attach` on a PTY | sbkeeper streams the ConPTY output (+ a replay buffer for new viewers) |
| Pane id in hooks | `$TMUX_PANE` | `$SWITCHBOARD_PANE`, set by sbkeeper |
| Launcher kind | `/proc/<pid>/environ` | `psutil` environment of `claude.exe` |
| Survives a node restart | yes | yes (sbkeeper holds the chats; the node can restart or update) |
| Survives a keeper restart/reboot | reboot: no | no |

sbkeeper listens on `127.0.0.1` only (port `keeper_port`, default 8097) with a random key from `keeper.key`
(mode: user-only ACL). Its API mirrors the `Tmux` class: `windows`, `new_window`, `rename`, `kill`, `send_keys`,
`capture`, `snapshot`, `pane_info`, and a websocket `attach` (binary in/out, `{"resize"}` text frames).
sbkeeper is deliberately small and rarely changes, because updating it ends open chats.

Both run as Scheduled Tasks at logon (hidden, restart on failure). The firewall rule opens the node port on the
Private and Tailscale profiles only.

## Planned for later (not in 1.3.0)
- **Signed machine list (roster):** the phone holds an Ed25519 key and signs `{seq, nodes:[{id,name,hosts,port,pin}]}`.
  Nodes store it (`PUT/GET /api/roster`) so any paired device can learn every machine from one node, and a stolen
  node can't add machines. Needed once there are more than two or three machines.
- **Wake:** a node that is up wakes another (Wake-on-LAN or Home Assistant). Needs BIOS WoL on the target.
- **Always-on helper node** (alert archive, Vigil) on a NAS.
- **Second push channel** (e.g. ntfy) next to Home Assistant.

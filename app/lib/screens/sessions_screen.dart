import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/hub.dart';
import '../main.dart';
import '../skins/chrome.dart';
import '../skins/mascot.dart';
import '../skins/skins.dart';
import '../widgets/action_bar.dart';

/// All chats (tmux windows) with live status; answer pending prompts right from the list.
class SessionsScreen extends StatelessWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([hub, settings]),
      builder: (context, _) {
        final skin = settings.skin;
        final link = hub.link;
        final multi = hub.nodes.length > 1;
        final up = hub.nodes.where((n) => n.link == LinkState.online).length;
        final sub = multi
            ? '$up of ${hub.nodes.length} machines online'
            : switch (link) {
                LinkState.online => '${hub.nodes.first.name} · ${where(hub.nodes.first)}',
                LinkState.connecting => 'connecting…',
                LinkState.offline => 'offline${hub.nodes.isNotEmpty && hub.nodes.first.error != null ? ' · retrying' : ''}',
              };
        final pending = hub.sessions.where((s) => s.pending != null).toList();
        final mood = link != LinkState.online
            ? 'offline'
            : pending.isNotEmpty
                ? pending.first.status
                : hub.sessions.any((s) => s.status == 'working')
                    ? 'working'
                    : hub.sessions.any((s) => s.status == 'done')
                        ? 'done'
                        : (DateTime.now().hour < 6 ? 'sleep' : 'idle');
        return Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: FloatingActionButton(
            onPressed: () => _newSession(context),
            tooltip: 'New chat',
            child: const Icon(Icons.add),
          ),
          body: RefreshIndicator(
            onRefresh: () async {
              if (hub.link != LinkState.online) await hub.connect();
              await hub.refresh();
            },
            child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
              SkinHeader(skin: skin, title: 'Switchboard', subtitle: sub, actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(Icons.circle, size: 12, color: link == LinkState.online ? skin.ok : skin.danger),
                ),
              ]),
              MikoBanner(
                skin: skin,
                settings: settings,
                state: mood,
                session: _moodSession(pending, mood),
              ),
              if (hub.sessions.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(link == LinkState.online ? 'No chats yet. Tap + to start one.' : 'Waiting for the bridge…',
                      textAlign: TextAlign.center, style: TextStyle(color: skin.dim)),
                ),
              if (!multi)
                for (final s in hub.sessions) _SessionCard(s: s, skin: skin)
              else
                for (final n in hub.nodes) ...[
                  MachineHeader(node: n, skin: skin),
                  if (n.sessions.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                      child: Text(n.link == LinkState.online ? 'no chats' : 'not reachable right now',
                          style: TextStyle(color: skin.dim, fontSize: 12)),
                    ),
                  for (final s in n.sessions) _SessionCard(s: s, skin: skin),
                ],
            ]),
          ),
        );
      },
    );
  }

  /// The chat Miko talks about: the one that needs you, else the busy one, else the one that just finished.
  String _moodSession(List<Session> pending, String mood) {
    if (pending.isNotEmpty) return pending.first.name;
    for (final st in [mood, 'working', 'done']) {
      for (final s in hub.sessions) {
        if (s.status == st) return s.name;
      }
    }
    return hub.sessions.isNotEmpty ? hub.sessions.first.name : 'everything';
  }

  Future<void> _newSession(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const NewSessionSheet(),
    );
  }
}

/// "home lan" / "tailscale": how the app reaches a machine right now.
String where(NodeLink n) {
  final via = n.api?.activeHost;
  return via == null ? '' : (via.startsWith('100.') ? 'tailscale' : 'home lan');
}

/// Machine name + status line above its chats (shown when more than one machine is paired).
class MachineHeader extends StatelessWidget {
  final NodeLink node;
  final Skin skin;
  const MachineHeader({super.key, required this.node, required this.skin});

  @override
  Widget build(BuildContext context) {
    final on = node.link == LinkState.online;
    final state = switch (node.link) {
      LinkState.online => where(node),
      LinkState.connecting => 'connecting…',
      LinkState.offline => 'offline',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      child: Row(children: [
        Icon(node.os == 'windows' ? Icons.laptop_windows : Icons.dns_outlined, size: 18, color: on ? skin.accent : skin.dim),
        const SizedBox(width: 8),
        Text(skin.head(node.name), style: TextStyle(color: skin.fg, fontWeight: FontWeight.w700, fontFamily: skin.headFont)),
        const SizedBox(width: 8),
        Icon(Icons.circle, size: 8, color: on ? skin.ok : skin.danger),
        const SizedBox(width: 4),
        Text(state, style: TextStyle(color: skin.dim, fontSize: 12)),
        const Spacer(),
        if (!on)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Try again',
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: node.connect,
          ),
      ]),
    );
  }
}

class _SessionCard extends StatelessWidget {
  final Session s;
  final Skin skin;
  const _SessionCard({required this.s, required this.skin});

  @override
  Widget build(BuildContext context) {
    final c = statusColor(skin, s.status);
    final l = (s.node ?? hub0)?.launcher(s.kind) ?? Launcher(s.kind, s.kind, s.kind);
    final kindLabel = l.label.toUpperCase();
    final kindColor = l.accent == 2 ? skin.accent2 : skin.accent;
    return SkinPanel(
      skin: skin,
      tint: c,
      onTap: () => openTerminal(s),
      onLongPress: () => _menu(context),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
                color: kindColor.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(skin.radius.clamp(0, 8))),
            child: Text(kindLabel,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1,
                    color: kindColor)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(skin.head(s.name), overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: skin.fg, fontFamily: skin.headFont)),
          ),
          if (s.status == 'working')
            SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: c)),
          const SizedBox(width: 6),
          Text(skin.head(statusLabel(s.status)), style: TextStyle(color: c, fontSize: 12)),
        ]),
        const SizedBox(height: 4),
        Text('${s.shortCwd}${s.model != null ? '  ·  ${s.model}' : ''}',
            style: TextStyle(color: skin.dim, fontSize: 12, fontFamily: 'JetBrainsMono'), overflow: TextOverflow.ellipsis),
        if (s.last.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('❯ ${s.last}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: skin.fg.withValues(alpha: 0.75), fontSize: 13)),
          ),
        if (s.pending != null) ...[
          const SizedBox(height: 8),
          ActionBar(alert: s.pending!, skin: skin, compact: true),
        ],
      ]),
    );
  }

  Future<void> _menu(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.edit), title: const Text('Rename'), onTap: () => Navigator.pop(context, 'rename')),
          ListTile(leading: const Icon(Icons.copy), title: const Text('Copy folder path'), onTap: () => Navigator.pop(context, 'copy')),
          ListTile(
              leading: Icon(Icons.delete_forever, color: skin.danger),
              title: Text('End this chat (kill the window)', style: TextStyle(color: skin.danger)),
              onTap: () => Navigator.pop(context, 'kill')),
        ]),
      ),
    );
    if (!context.mounted) return;
    if (choice == 'copy') {
      Clipboard.setData(ClipboardData(text: s.cwd));
      toast('Copied ${s.cwd}');
    } else if (choice == 'rename') {
      final ctrl = TextEditingController(text: s.name);
      final name = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Rename chat'),
          content: TextField(controller: ctrl, autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Rename')),
          ],
        ),
      );
      if (name != null && name.isNotEmpty) await s.node!.rename(s, name);
    } else if (choice == 'kill') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('End "${s.name}"?'),
          content: const Text('This closes the chat window and whatever runs in it. It cannot be undone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: skin.danger),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('End chat')),
          ],
        ),
      );
      if (ok == true) await s.node!.kill(s);
    }
  }
}

/// Start a new chat with one of the bridge's launchers (Claude, a local agent, a shell…) in a folder on the bridge computer.
IconData launcherIcon(String icon) => switch (icon) {
      'cloud' => Icons.cloud_outlined,
      'terminal' => Icons.terminal,
      'spark' => Icons.auto_awesome,
      _ => Icons.memory,
    };

class NewSessionSheet extends StatefulWidget {
  const NewSessionSheet({super.key});
  @override
  State<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<NewSessionSheet> {
  // the machine: the first one that is online (the user can switch when several are paired)
  late NodeLink node = hub.nodes.firstWhere((n) => n.link == LinkState.online, orElse: () => hub.nodes.first);
  late String kind = node.launchers.first.kind;
  String? path;
  List<Map<String, dynamic>> items = [];
  List<String> roots = [];
  final nameCtrl = TextEditingController();
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load(null);
  }

  Future<void> _load(String? p) async {
    try {
      final r = await node.api!.get('/api/fs', query: {'path': ?p}) as Map;
      setState(() {
        path = r['path'] as String;
        roots = (r['roots'] as List).cast<String>();
        items = (r['items'] as List).cast<Map<String, dynamic>>().where((i) => i['dir'] == true).toList();
      });
    } catch (e) {
      toast('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final skin = settings.skin;
    final sep = node.sep;
    final cut = path?.lastIndexOf(sep) ?? -1;
    final parent = path == null || roots.contains(path) || cut <= 0
        ? null
        : path!.substring(0, sep == '\\' && cut == 2 ? 3 : cut); // keep "C:\\" a folder
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(skin.head('New chat'), style: TextStyle(fontSize: 20, fontFamily: skin.headFont, color: skin.fg)),
            ),
            if (hub.nodes.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Wrap(spacing: 8, runSpacing: 6, children: [
                  for (final n in hub.nodes)
                    ChoiceChip(
                      avatar: Icon(n.os == 'windows' ? Icons.laptop_windows : Icons.dns_outlined, size: 18),
                      label: Text(n.name),
                      selected: node == n,
                      onSelected: n.link != LinkState.online
                          ? null
                          : (_) {
                              setState(() {
                                node = n;
                                kind = n.launchers.first.kind;
                                path = null;
                                items = [];
                              });
                              _load(null);
                            },
                    ),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(spacing: 8, runSpacing: 6, children: [
                for (final l in node.launchers)
                  ChoiceChip(
                    avatar: Icon(launcherIcon(l.icon), size: 18),
                    label: Text(l.label),
                    selected: kind == l.kind,
                    onSelected: (_) => setState(() => kind = l.kind),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name (optional)', isDense: true)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(children: [
                Icon(Icons.folder_open, size: 18, color: skin.accent),
                const SizedBox(width: 6),
                Expanded(child: Text(path ?? '…', style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: skin.fg))),
              ]),
            ),
            Expanded(
              child: ListView(children: [
                for (final r in roots)
                  if (r != path) ListTile(dense: true, leading: const Icon(Icons.home_outlined), title: Text(r), onTap: () => _load(r)),
                if (parent != null)
                  ListTile(dense: true, leading: const Icon(Icons.arrow_upward), title: const Text('..'), onTap: () => _load(parent)),
                for (final i in items)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(i['name'] as String),
                    onTap: () => _load('${path!.endsWith(sep) ? path : '$path$sep'}${i['name']}'),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: busy || path == null
                    ? null
                    : () async {
                        setState(() => busy = true);
                        try {
                          final id = await node.newSession(kind, path!, nameCtrl.text.trim());
                          if (!context.mounted) return;
                          Navigator.pop(context);
                          final s = node.sessionById(id);
                          if (s != null) openTerminal(s);
                        } catch (e) {
                          toast('$e');
                          setState(() => busy = false);
                        }
                      },
                icon: const Icon(Icons.play_arrow),
                label: Text('Start ${node.launcher(kind).label}${hub.nodes.length > 1 ? ' on ${node.name}' : ''} here'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

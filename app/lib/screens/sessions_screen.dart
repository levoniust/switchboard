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
        final via = hub.api?.activeHost;
        final where = via == null ? '' : (via.startsWith('100.') ? 'tailscale' : 'home lan');
        final sub = switch (link) {
          LinkState.online => '${hub.server?.name ?? ''} · $where',
          LinkState.connecting => 'connecting…',
          LinkState.offline => 'offline${hub.error != null ? ' · retrying' : ''}',
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
              for (final s in hub.sessions) _SessionCard(s: s, skin: skin),
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

class _SessionCard extends StatelessWidget {
  final Session s;
  final Skin skin;
  const _SessionCard({required this.s, required this.skin});

  @override
  Widget build(BuildContext context) {
    final c = statusColor(skin, s.status);
    final kindLabel = switch (s.kind) { 'claude' => 'CLAUDE', 'claude-local' => 'QWEN', _ => 'SHELL' };
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
                color: (s.kind == 'claude-local' ? skin.accent2 : skin.accent).withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(skin.radius.clamp(0, 8))),
            child: Text(kindLabel,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1,
                    color: s.kind == 'claude-local' ? skin.accent2 : skin.accent)),
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
      if (name != null && name.isNotEmpty) await hub.rename(s, name);
    } else if (choice == 'kill') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('End "${s.name}"?'),
          content: const Text('This closes the tmux window and whatever runs in it. It cannot be undone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: skin.danger),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('End chat')),
          ],
        ),
      );
      if (ok == true) await hub.kill(s);
    }
  }
}

/// Start a new chat: claude, claude-local or a shell, in a folder picked on the bridge computer.
class NewSessionSheet extends StatefulWidget {
  const NewSessionSheet({super.key});
  @override
  State<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<NewSessionSheet> {
  String kind = 'claude';
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
      final r = await hub.api!.get('/api/fs', query: {'path': ?p}) as Map;
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
    final parent = path == null || roots.contains(path) ? null : path!.substring(0, path!.lastIndexOf('/'));
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'claude', label: Text('Claude'), icon: Icon(Icons.cloud_outlined)),
                  ButtonSegment(value: 'claude-local', label: Text('Qwen'), icon: Icon(Icons.memory)),
                  ButtonSegment(value: 'shell', label: Text('Shell'), icon: Icon(Icons.terminal)),
                ],
                selected: {kind},
                onSelectionChanged: (v) => setState(() => kind = v.first),
              ),
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
                    onTap: () => _load('$path/${i['name']}'),
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
                          final id = await hub.newSession(kind, path!, nameCtrl.text.trim());
                          if (!context.mounted) return;
                          Navigator.pop(context);
                          final s = hub.sessionById(id);
                          if (s != null) openTerminal(s);
                        } catch (e) {
                          toast('$e');
                          setState(() => busy = false);
                        }
                      },
                icon: const Icon(Icons.play_arrow),
                label: Text('Start ${kind == 'claude-local' ? 'claude-local' : kind} here'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

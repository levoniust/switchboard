import 'package:flutter/material.dart';

import '../core/api.dart';
import '../main.dart';
import '../skins/chrome.dart';
import '../skins/skins.dart';
import 'pair_screen.dart';
import 'skin_gallery_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([settings, hub]),
      builder: (context, _) {
        final skin = settings.skin;
        return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
          SkinHeader(skin: skin, title: 'Settings'),
          _section(skin, 'Skin'),
          SizedBox(
            height: 150,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              for (final s in settings.available) _SkinTile(s: s, selected: s.id == skin.id),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(skin.blurb, style: TextStyle(color: skin.dim, fontSize: 13)),
          ),
          if (skin.miko != null && settings.mikoPictures(skin.miko!).isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: Icon(Icons.photo_library_outlined, color: skin.accent),
                  label: Text('View pictures (${settings.mikoPictures(skin.miko!).length})', style: TextStyle(color: skin.accent)),
                  onPressed: () => _openGallery(context, skin),
                ),
              ),
            ),
          _section(skin, 'Terminal text'),
          Row(children: [
            const SizedBox(width: 16),
            Text('${settings.fontSize.round()}', style: TextStyle(color: skin.fg, fontFamily: 'JetBrainsMono')),
            Expanded(
              child: Slider(value: settings.fontSize, min: 8, max: 24, divisions: 16, onChanged: settings.setFontSize),
            ),
          ]),
          _section(skin, 'Chats'),
          SwitchListTile(
            title: Text('Open chats in Reader view', style: TextStyle(color: skin.fg)),
            subtitle: Text('Native text that re-wraps on rotate and pinch-zoom without touching the PC. Off = raw terminal.',
                style: TextStyle(color: skin.dim, fontSize: 12)),
            value: settings.readerDefault,
            onChanged: settings.setReaderDefault,
          ),
          SwitchListTile(
            title: Text('Join wrapped lines', style: TextStyle(color: skin.fg)),
            subtitle: Text('Reader: glue lines the CLI broke at the PC\'s width back into paragraphs.',
                style: TextStyle(color: skin.dim, fontSize: 12)),
            value: settings.joinLines,
            onChanged: settings.setJoinLines,
          ),
          Row(children: [
            const SizedBox(width: 16),
            Text('Reader text ${settings.readerFontSize.round()}', style: TextStyle(color: skin.fg)),
            Expanded(
              child: Slider(value: settings.readerFontSize, min: 9, max: 30, divisions: 21, onChanged: settings.setReaderFontSize),
            ),
          ]),
          SwitchListTile(
            title: Text('Haptic feedback', style: TextStyle(color: skin.fg)),
            value: settings.haptics,
            onChanged: settings.setHaptics,
          ),
          _section(skin, 'Connection'),
          ListTile(
            title: Text(hub.server?.name ?? 'Not paired', style: TextStyle(color: skin.fg)),
            subtitle: Text(
              '${hub.server?.hosts.join(' → ') ?? ''}\nusing ${hub.api?.activeHost ?? '—'} · ${hub.link.name}',
              style: TextStyle(color: skin.dim, fontFamily: 'JetBrainsMono', fontSize: 12),
            ),
            isThreeLine: true,
            trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: hub.connect),
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: Text('Pair again', style: TextStyle(color: skin.fg)),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PairScreen())),
          ),
          ListTile(
            leading: Icon(Icons.link_off, color: skin.danger),
            title: Text('Forget this bridge', style: TextStyle(color: skin.danger)),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Forget the bridge?'),
                  content: const Text('The app deletes its access key. You will need a new pairing link.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Forget')),
                  ],
                ),
              );
              if (ok == true) {
                await Server.forget();
                hub.pause();
                hub.server = null;
                hub.api = null;
                navKey.currentState?.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const PairScreen()), (_) => false);
              }
            },
          ),
          _section(skin, 'Notifications'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'When the app is closed, alerts arrive through the Home Assistant companion app '
              '(no need to keep Switchboard awake). Tapping one opens Switchboard at that prompt; '
              'its buttons answer directly.',
              style: TextStyle(color: skin.dim, fontSize: 13),
            ),
          ),
          _section(skin, 'About'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Switchboard 1.2.0 · a phone switchboard for Claude Code and claude-local.\n'
                'Fonts: JetBrains Mono, Roboto, Antonio, Orbitron, Rajdhani, Share Tech Mono, VT323 (SIL OFL).',
                style: TextStyle(color: skin.dim, fontSize: 12)),
          ),
        ]);
      },
    );
  }

  Widget _section(Skin skin, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(skin.head(t), style: TextStyle(color: skin.accent, fontWeight: FontWeight.w700, letterSpacing: 1, fontSize: 13)),
      );
}

void _openGallery(BuildContext context, Skin s) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SkinGalleryScreen(skin: s)));

class _SkinTile extends StatelessWidget {
  final Skin s;
  final bool selected;
  const _SkinTile({required this.s, required this.selected});

  @override
  Widget build(BuildContext context) {
    final img = s.miko != null ? settings.mikoImage(s.miko!, 'idle') : null;
    return GestureDetector(
      onTap: () => settings.setSkin(s.id),
      // long-press a mascot skin to see its pictures without switching to it
      onLongPress: s.miko == null ? null : () => _openGallery(context, s),
      child: Container(
        width: 116,
        margin: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: s.bg,
          borderRadius: BorderRadius.circular(s.radius.clamp(0, 16)),
          border: Border.all(color: selected ? s.accent : s.dim.withValues(alpha: 0.4), width: selected ? 3 : 1),
          image: img == null ? null : DecorationImage(image: AssetImage(img), fit: BoxFit.cover, opacity: 0.55),
        ),
        padding: const EdgeInsets.all(8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [for (final c in s.bands.take(4)) Expanded(child: Container(height: 6, color: c))]),
          const Spacer(),
          Text(s.head(s.name), style: TextStyle(color: s.fg, fontFamily: s.headFont, fontSize: 14, fontWeight: FontWeight.w700,
              shadows: img == null ? null : const [Shadow(blurRadius: 4)])),
          Text('> _', style: TextStyle(color: s.term.foreground, fontFamily: s.termFont, fontSize: 12)),
        ]),
      ),
    );
  }
}

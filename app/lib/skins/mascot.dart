import 'package:flutter/material.dart';

import '../core/settings.dart';
import 'skins.dart';

/// Miko banner: her picture for the current state + a line in the skin's voice. Private build only;
/// renders nothing in skins without a mascot.
class MikoBanner extends StatelessWidget {
  final Skin skin;
  final Settings settings;
  final String state;
  final String session;
  final String? fallback;
  const MikoBanner({super.key, required this.skin, required this.settings, required this.state, this.session = 'that chat', this.fallback});

  @override
  Widget build(BuildContext context) {
    final set = skin.miko;
    if (set == null || !settings.mikoAvailable) return const SizedBox.shrink();
    final img = settings.mikoImage(set, state);
    final line = settings.mikoLine(set, state, session: session) ?? fallback ?? '';
    final chibi = set == MikoSet.chibi || set == MikoSet.chibiNight || set == MikoSet.chibiCozy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (img != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(chibi ? 0 : 18),
            child: Image.asset(img, width: chibi ? 92 : 84, height: chibi ? 92 : 84, fit: BoxFit.cover, gaplessPlayback: true),
          ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: skin.surface,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(chibi ? 22 : 14),
                topRight: Radius.circular(chibi ? 22 : 14),
                bottomRight: Radius.circular(chibi ? 22 : 14),
                bottomLeft: const Radius.circular(4),
              ),
              border: Border.all(color: skin.accent.withValues(alpha: 0.35)),
            ),
            child: Text(line, style: TextStyle(color: skin.fg, fontSize: chibi ? 15 : 14, height: 1.3)),
          ),
        ),
      ]),
    );
  }
}

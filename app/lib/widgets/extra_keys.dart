import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/keys.dart';
import '../main.dart';
import '../skins/skins.dart';

/// Termux-style extra keys that sit on top of the phone keyboard: two rows that fill the width.
/// Tap sends the key; swipe up on a key with a small corner label sends that instead.
/// CTRL / ALT: tap = on for the next key, long-press = locked, tap again = off.
class ExtraKeys extends StatelessWidget {
  final Skin skin;
  final Modifiers mods;
  final void Function(String seq) onKey;
  final bool online;
  const ExtraKeys({super.key, required this.skin, required this.mods, required this.onKey, this.online = true});

  void _press(BuildContext context, XKey k, {bool up = false}) {
    if (settings.haptics) HapticFeedback.selectionClick();
    if (k.mod != null) return mods.tap(k.mod!);
    if (k.more) {
      _more(context);
      return;
    }
    onKey(mods.apply(up && k.upSeq != null ? k.upSeq! : k.seq));
  }

  Future<void> _more(BuildContext context) async {
    final k = await showModalBottomSheet<XKey>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final k in moreKeys)
              ActionChip(
                label: Text(k.label, style: const TextStyle(fontFamily: 'JetBrainsMono')),
                onPressed: () => Navigator.pop(context, k),
              ),
          ]),
        ),
      ),
    );
    if (k != null) onKey(mods.apply(k.seq));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mods,
      builder: (context, _) => Container(
        color: skin.surface,
        child: SafeArea(
          top: false,
          child: Opacity(
            opacity: online ? 1 : 0.45,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final row in extraKeyRows)
                SizedBox(
                  height: 42,
                  child: Row(children: [for (final k in row) Expanded(child: _key(context, k))]),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _key(BuildContext context, XKey k) {
    final state = k.mod == 'ctrl' ? mods.ctrl : k.mod == 'alt' ? mods.alt : ModState.off;
    final lit = state != ModState.off;
    var swiped = false;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _press(context, k),
      onLongPress: k.mod != null ? () => mods.lock(k.mod!) : null,
      onVerticalDragStart: (_) => swiped = false,
      onVerticalDragUpdate: (d) {
        if (!swiped && d.localPosition.dy < -12) {
          swiped = true;
          _press(context, k, up: true);
        }
      },
      child: Container(
        margin: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(
          color: lit ? skin.accent : skin.bg,
          borderRadius: BorderRadius.circular(skin.radius.clamp(0, 6)),
          border: Border.all(
              color: state == ModState.locked ? skin.fg : skin.dim.withValues(alpha: 0.35), width: state == ModState.locked ? 2 : 1),
        ),
        child: Stack(children: [
          Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(k.label,
                    style: TextStyle(
                        color: lit ? skin.bg : skin.fg,
                        fontFamily: 'JetBrainsMono',
                        fontSize: k.label.length > 2 ? 12 : 16,
                        fontWeight: lit ? FontWeight.bold : FontWeight.normal)),
              ),
            ),
          ),
          if (k.upLabel != null)
            Positioned(
              top: 1,
              right: 3,
              child: Text(k.upLabel!, style: TextStyle(color: skin.dim, fontSize: 9, fontFamily: 'JetBrainsMono')),
            ),
        ]),
      ),
    );
  }
}

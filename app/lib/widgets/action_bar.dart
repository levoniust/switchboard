import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/hub.dart';
import '../main.dart';
import '../skins/skins.dart';

/// Big answer buttons for a pending permission prompt or question. Reads the dialog's real choices from
/// the screen (e.g. "Yes / Yes, and always allow … / No") and presses the matching number in the chat.
class ActionBar extends StatefulWidget {
  final Alert alert;
  final Skin skin;
  final bool compact;
  const ActionBar({super.key, required this.alert, required this.skin, this.compact = false});
  @override
  State<ActionBar> createState() => _ActionBarState();
}

class _ActionBarState extends State<ActionBar> {
  List<AlertOption>? _opts;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  @override
  void didUpdateWidget(ActionBar old) {
    super.didUpdateWidget(old);
    if (old.alert.id != widget.alert.id) _loadOptions();
  }

  Future<void> _loadOptions() async {
    try {
      for (var i = 0; i < 3 && mounted; i++) {
        final a = await hub.alert(widget.alert.id);
        if (a.screenOptions.length >= 2) {
          if (mounted) setState(() => _opts = a.screenOptions);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    } catch (_) {}
  }

  List<AlertOption> get _options {
    // questions: the hook carries the full option list; permissions: read the real choices off the screen
    if (widget.alert.type == 'question' && widget.alert.options.isNotEmpty) return widget.alert.options;
    if (_opts != null && _opts!.length >= 2) return _opts!;
    if (widget.alert.options.isNotEmpty) return widget.alert.options;
    return [AlertOption('1', 'Yes'), AlertOption('no', 'No')];
  }

  Future<void> _answer(AlertOption o) async {
    setState(() => _busy = true);
    if (settings.haptics) HapticFeedback.lightImpact();
    try {
      final label = await hub.answer(widget.alert.id, o.key);
      toast('Answered: $label');
    } catch (e) {
      toast('$e');
      _loadOptions();
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final skin = widget.skin;
    final a = widget.alert;
    final opts = _options;
    final icon = a.type == 'question' ? Icons.help_outline : Icons.shield_outlined;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(icon, size: 18, color: skin.accent2),
        const SizedBox(width: 6),
        Expanded(
          child: Text(a.title, style: TextStyle(color: skin.fg, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ]),
      if (a.body.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Text(a.body,
              maxLines: widget.compact ? 2 : 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: skin.fg.withValues(alpha: 0.8), fontSize: 12, fontFamily: 'JetBrainsMono')),
        ),
      const SizedBox(height: 4),
      Wrap(spacing: 8, runSpacing: 6, children: [
        for (final o in opts)
          _isNo(o)
              ? OutlinedButton(onPressed: _busy ? null : () => _answer(o), child: Text(_short(o.label)))
              : FilledButton(
                  onPressed: _busy ? null : () => _answer(o),
                  style: FilledButton.styleFrom(
                    backgroundColor: o.key == '1' ? skin.accent : skin.accent2,
                    foregroundColor: skin.brightness == Brightness.dark ? Colors.black : Colors.white,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(_short(o.label)),
                ),
      ]),
    ]);
  }

  bool _isNo(AlertOption o) => o.label.toLowerCase().startsWith('no') || o.label.toLowerCase().startsWith('chat about');

  String _short(String l) {
    // "Yes, and always allow access to /very/long/path from this project" -> keep it button-sized
    final t = l.replaceAll(RegExp(r'\s+·.*$'), '');
    return t.length > 42 ? '${t.substring(0, 40)}…' : t;
  }
}

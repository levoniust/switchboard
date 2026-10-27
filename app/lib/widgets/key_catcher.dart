import 'package:flutter/material.dart';

import '../core/keys.dart';

/// Invisible text field that turns phone-keyboard input into terminal keys for the raw terminal view:
/// typed text goes out as-is (through CTRL/ALT if armed), Backspace = DEL, Enter = CR, and moving the
/// cursor with the keyboard's own arrow keys (Samsung) or a space-bar swipe (Gboard) = arrow keys.
class KeyCatcher extends StatefulWidget {
  final FocusNode focusNode;
  final Modifiers mods;
  final void Function(String seq) onKey;
  const KeyCatcher({super.key, required this.focusNode, required this.mods, required this.onKey});

  @override
  State<KeyCatcher> createState() => _KeyCatcherState();
}

class _KeyCatcherState extends State<KeyCatcher> {
  // The cursor sits in the middle of four spaces so moves either way and deletes are visible.
  static const _sentinel = TextEditingValue(text: '    ', selection: TextSelection.collapsed(offset: 2));
  final ctrl = TextEditingController.fromValue(_sentinel);
  bool _resetting = false;

  @override
  void initState() {
    super.initState();
    ctrl.addListener(_changed);
  }

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  void _reset() {
    _resetting = true;
    ctrl.value = _sentinel;
    _resetting = false;
  }

  void _changed() {
    if (_resetting) return;
    final v = ctrl.value;
    if (v.composing.isValid && !v.composing.isCollapsed) return; // wait for the keyboard to finish a word
    final text = v.text;
    if (text == _sentinel.text) {
      final o = v.selection.baseOffset;
      if (!v.selection.isCollapsed || o == 2) return;
      widget.onKey(widget.mods.apply(switch (o) { 0 => '\x1b[A', 1 => '\x1b[D', 3 => '\x1b[C', _ => '\x1b[B' }));
      _reset();
      return;
    }
    if (text.length < _sentinel.text.length) {
      for (var i = text.length; i < _sentinel.text.length; i++) {
        widget.onKey(widget.mods.apply('\x7f'));
      }
    } else {
      // Inserted text = whatever is not the sentinel's spaces around it.
      final ins = text.substring(2, text.length - 2).replaceAll('\n', '\r');
      for (final ch in ins.characters) {
        widget.onKey(widget.mods.apply(ch));
      }
    }
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 1,
      height: 1,
      child: Opacity(
        opacity: 0,
        child: TextField(
          controller: ctrl,
          focusNode: widget.focusNode,
          keyboardType: TextInputType.visiblePassword, // no autocorrect or suggestions
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          textInputAction: TextInputAction.send,
          onSubmitted: (_) => widget.onKey(widget.mods.apply('\r')),
          onEditingComplete: () {}, // keep the keyboard open after Enter
          showCursor: false,
          decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true),
        ),
      ),
    );
  }
}

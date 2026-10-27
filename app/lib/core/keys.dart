import 'package:flutter/foundation.dart';

/// A sticky modifier key: tap = on for the next key only, long-press = locked on, tap again = off.
enum ModState { off, once, locked }

/// Ctrl / Alt state shared by the extra-keys row, the Reader input line and raw typing
/// (Termux-style: press CTRL, then a letter on the phone keyboard).
class Modifiers extends ChangeNotifier {
  ModState ctrl = ModState.off, alt = ModState.off;

  bool get any => ctrl != ModState.off || alt != ModState.off;

  void tap(String which) {
    final cur = which == 'ctrl' ? ctrl : alt;
    final next = cur == ModState.off ? ModState.once : ModState.off;
    which == 'ctrl' ? ctrl = next : alt = next;
    notifyListeners();
  }

  void lock(String which) {
    which == 'ctrl' ? ctrl = ModState.locked : alt = ModState.locked;
    notifyListeners();
  }

  /// Applies the active modifiers to [seq] (one typed character or a key's escape sequence)
  /// and releases the one-shot ones.
  String apply(String seq) {
    if (!any) return seq;
    final out = withMods(seq, ctrl: ctrl != ModState.off, alt: alt != ModState.off);
    var changed = false;
    if (ctrl == ModState.once) {
      ctrl = ModState.off;
      changed = true;
    }
    if (alt == ModState.once) {
      alt = ModState.off;
      changed = true;
    }
    if (changed) notifyListeners();
    return out;
  }
}

final _csi = RegExp(r'^\x1b\[([0-9]*)([A-DHF~])$');

/// xterm encoding of [seq] with Ctrl and/or Alt held.
String withMods(String seq, {bool ctrl = false, bool alt = false}) {
  if (!ctrl && !alt) return seq;
  // Arrows, Home/End (ESC [ X) and PgUp/PgDn (ESC [ n ~) take a modifier parameter.
  final m = _csi.firstMatch(seq);
  if (m != null) {
    final mod = 1 + (alt ? 2 : 0) + (ctrl ? 4 : 0);
    final n = m.group(1)!, end = m.group(2)!;
    return end == '~' ? '\x1b[$n;$mod~' : '\x1b[1;$mod$end';
  }
  var s = seq;
  if (ctrl && s.length == 1) s = ctrlChar(s);
  return alt ? '\x1b$s' : s;
}

/// Control character for Ctrl+[c] (Ctrl+A = 0x01 … Ctrl+Z = 0x1a, Ctrl+Space = NUL, Ctrl+[ = ESC …).
String ctrlChar(String c) {
  final u = c.toUpperCase().codeUnitAt(0);
  if (u >= 0x40 && u <= 0x5f) return String.fromCharCode(u - 0x40); // @ A-Z [ \ ] ^ _
  if (c == ' ' || c == '2') return '\x00';
  if (c == '?' || c == '8') return '\x7f';
  if (c == '3') return '\x1b';
  if (c == '4') return '\x1c';
  if (c == '5') return '\x1d';
  if (c == '6') return '\x1e';
  if (c == '7' || c == '/') return '\x1f';
  return c;
}

/// One key on the extra-keys row: label + what it sends, and an optional swipe-up alternative.
class XKey {
  final String label, seq;
  final String? upLabel, upSeq;
  final String? mod; // 'ctrl' / 'alt' for the sticky modifiers
  final bool more; // opens the "more keys" sheet
  const XKey(this.label, this.seq, {this.upLabel, this.upSeq, this.mod, this.more = false});
}

const esc = '\x1b', enter = '\r';

/// Termux-like layout: two full-width rows, nothing scrolls off screen.
const extraKeyRows = <List<XKey>>[
  [
    XKey('ESC', esc, upLabel: '^C', upSeq: '\x03'),
    XKey('/', '/', upLabel: '\\', upSeq: '\\'),
    XKey('-', '-', upLabel: '|', upSeq: '|'),
    XKey('HOME', '\x1b[H'),
    XKey('↑', '\x1b[A'),
    XKey('END', '\x1b[F'),
    XKey('PGUP', '\x1b[5~'),
    XKey('⏎', enter, upLabel: 'nl', upSeq: '\x1b\r'),
  ],
  [
    XKey('TAB', '\t', upLabel: '⇧', upSeq: '\x1b[Z'),
    XKey('CTRL', '', mod: 'ctrl'),
    XKey('ALT', '', mod: 'alt'),
    XKey('←', '\x1b[D'),
    XKey('↓', '\x1b[B'),
    XKey('→', '\x1b[C'),
    XKey('PGDN', '\x1b[6~'),
    XKey('•••', '', more: true),
  ],
];

/// Keys in the "more" sheet.
const moreKeys = <XKey>[
  XKey('^C', '\x03'),
  XKey('^D', '\x04'),
  XKey('^R', '\x12'),
  XKey('^L', '\x0c'),
  XKey('^Z', '\x1a'),
  XKey('^O', '\x0f'),
  XKey('⇧TAB', '\x1b[Z'),
  XKey('1', '1'),
  XKey('2', '2'),
  XKey('3', '3'),
  XKey('y', 'y'),
  XKey('n', 'n'),
  XKey('q', 'q'),
  XKey('!', '!'),
  XKey('@', '@'),
  XKey('#', '#'),
  XKey('~', '~'),
  XKey('`', '`'),
  XKey('DEL', '\x1b[3~'),
  XKey('tmux hist', '\x02[\x1b[5~'),
];

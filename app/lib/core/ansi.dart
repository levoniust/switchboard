import 'package:flutter/painting.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;

/// A piece of a line with one look.
class Run {
  final String text;
  final Color? fg, bg;
  final bool bold, dim, italic, underline;
  const Run(this.text, {this.fg, this.bg, this.bold = false, this.dim = false, this.italic = false, this.underline = false});

  Run withText(String t) => Run(t, fg: fg, bg: bg, bold: bold, dim: dim, italic: italic, underline: underline);
}

final _esc = RegExp(r'\x1b\[([0-9;:]*)([A-Za-z])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][A-Za-z0-9]|\x1b.');

/// Text without escape sequences.
String plain(String line) => line.replaceAll(_esc, '');

/// Splits a line captured with `tmux capture-pane -e` into styled runs (SGR colours/bold/italic/underline).
List<Run> parseAnsi(String line, TerminalTheme t) {
  final runs = <Run>[];
  Color? fg, bg;
  var bold = false, dim = false, italic = false, underline = false, inverse = false;
  var pos = 0;
  void emit(String s) {
    if (s.isEmpty) return;
    final f = inverse ? (bg ?? t.background) : fg, b = inverse ? (fg ?? t.foreground) : bg;
    runs.add(Run(s, fg: f, bg: b, bold: bold, dim: dim, italic: italic, underline: underline));
  }

  for (final m in _esc.allMatches(line)) {
    emit(line.substring(pos, m.start));
    pos = m.end;
    if (m.group(2) != 'm') continue;
    final ps = (m.group(1) ?? '').split(RegExp('[;:]')).map((e) => int.tryParse(e) ?? 0).toList();
    for (var i = 0; i < ps.length; i++) {
      final p = ps[i];
      if (p == 0) {
        fg = bg = null;
        bold = dim = italic = underline = inverse = false;
      } else if (p == 1) {
        bold = true;
      } else if (p == 2) {
        dim = true;
      } else if (p == 3) {
        italic = true;
      } else if (p == 4) {
        underline = true;
      } else if (p == 7) {
        inverse = true;
      } else if (p == 22) {
        bold = dim = false;
      } else if (p == 23) {
        italic = false;
      } else if (p == 24) {
        underline = false;
      } else if (p == 27) {
        inverse = false;
      } else if (p >= 30 && p <= 37) {
        fg = _basic(t, p - 30);
      } else if (p >= 90 && p <= 97) {
        fg = _basic(t, p - 90 + 8);
      } else if (p >= 40 && p <= 47) {
        bg = _basic(t, p - 40);
      } else if (p >= 100 && p <= 107) {
        bg = _basic(t, p - 100 + 8);
      } else if (p == 39) {
        fg = null;
      } else if (p == 49) {
        bg = null;
      } else if ((p == 38 || p == 48) && i + 1 < ps.length) {
        Color? c;
        if (ps[i + 1] == 5 && i + 2 < ps.length) {
          c = _x256(t, ps[i + 2]);
          i += 2;
        } else if (ps[i + 1] == 2 && i + 4 < ps.length) {
          c = Color.fromARGB(255, ps[i + 2], ps[i + 3], ps[i + 4]);
          i += 4;
        }
        p == 38 ? fg = c : bg = c;
      }
    }
  }
  emit(line.substring(pos));
  return runs;
}

Color _basic(TerminalTheme t, int i) => [
      t.black, t.red, t.green, t.yellow, t.blue, t.magenta, t.cyan, t.white, //
      t.brightBlack, t.brightRed, t.brightGreen, t.brightYellow, t.brightBlue, t.brightMagenta, t.brightCyan, t.brightWhite,
    ][i];

Color _x256(TerminalTheme t, int n) {
  if (n < 16) return _basic(t, n);
  if (n >= 232) {
    final v = 8 + (n - 232) * 10;
    return Color.fromARGB(255, v, v, v);
  }
  n -= 16;
  int c(int x) => x == 0 ? 0 : 55 + x * 40;
  return Color.fromARGB(255, c(n ~/ 36), c((n ~/ 6) % 6), c(n % 6));
}

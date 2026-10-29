import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;

import '../core/ansi.dart';
import '../skins/skins.dart';

/// What the Reader shows for a stretch of CLI lines.
sealed class Block {}

class Para extends Block {
  final List<Run> runs;
  Para(this.runs);
}

class Rule extends Block {}

/// Lines that were inside a ╭─╮ │ │ ╰─╯ box (Claude's input box, tool panels): shown in a native frame.
class Boxed extends Block {
  final List<List<Run>> lines;
  Boxed(this.lines);
}

final _rule = RegExp(r'^[─━═╌┄┈]{3,}$');
final _boxEdge = RegExp(r'^[╭┌╰└][─━═╌┄]*[╮┐╯┘]$');
final _listStart = RegExp(r'^(?:[●•◦○◆▪▸►⎿✓✔✗✘☐☒❯>*+\-]|\d+[.)])\s');

/// Turns the CLI's lines (with colour escapes) into blocks the phone lays out itself.
/// [width] is the PC window's width: with [join], a line that ran to (nearly) that width followed by
/// a plain continuation line was wrapped by the CLI, so the two are glued back into one paragraph.
List<Block> buildBlocks(List<String> lines, int width, bool join, TerminalTheme t, [Map<String, List<Run>>? cache]) {
  final out = <Block>[];
  List<Run> runsOf(String l) => cache == null ? parseAnsi(l, t) : (cache[l] ??= parseAnsi(l, t));
  var prevLen = 0;
  for (final line in lines) {
    final p = plain(line);
    final tr = p.trim();
    if (_rule.hasMatch(tr)) {
      out.add(Rule());
      prevLen = 0;
      continue;
    }
    if (_boxEdge.hasMatch(tr)) {
      if (tr.startsWith('╭') || tr.startsWith('┌')) out.add(Boxed([]));
      prevLen = 0;
      continue;
    }
    if (tr.length >= 2 && (tr.startsWith('│') || tr.startsWith('┃')) && (tr.endsWith('│') || tr.endsWith('┃'))) {
      final inner = _stripBorders(runsOf(line));
      if (out.isNotEmpty && out.last is Boxed) {
        (out.last as Boxed).lines.add(inner);
      } else {
        out.add(Boxed([inner]));
      }
      prevLen = 0;
      continue;
    }
    final runs = runsOf(line);
    final indent = p.length - p.trimLeft().length;
    // the CLI word-wraps: the line before ran to (nearly) the edge, or this line's first word would not have fit there
    final firstWord = tr.split(' ').first.length;
    final full = prevLen >= width - 12 || prevLen + 1 + firstWord > width - 2;
    final wrapped = join && tr.isNotEmpty && prevLen > 0 && full && width > 20 && !_listStart.hasMatch(tr) && out.isNotEmpty;
    if (wrapped && out.last is Para) {
      final last = out.last as Para;
      final rest = _dropLeading(runs, indent);
      // capture-pane -J keeps the padding after the last word; without trimming it the joined text shows a gap
      out[out.length - 1] = Para([..._trimEnd(last.runs), const Run(' '), ...rest]);
    } else {
      out.add(Para(runs));
    }
    prevLen = p.trimRight().length;
  }
  return out;
}

List<Run> _trimEnd(List<Run> runs) {
  final out = [...runs];
  while (out.isNotEmpty) {
    final t = out.last.text.trimRight();
    if (t.isNotEmpty) {
      out[out.length - 1] = out.last.withText(t);
      break;
    }
    out.removeLast();
  }
  return out;
}

List<Run> _dropLeading(List<Run> runs, int n) {
  final out = <Run>[];
  for (final r in runs) {
    if (n > 0) {
      final cut = r.text.length < n ? r.text.length : n;
      n -= cut;
      if (cut < r.text.length) out.add(r.withText(r.text.substring(cut)));
    } else {
      out.add(r);
    }
  }
  return out;
}

/// Removes the first and last box-drawing border (and the padding next to them) from a boxed line.
List<Run> _stripBorders(List<Run> runs) {
  final text = runs.map((r) => r.text).join();
  final a = text.indexOf(RegExp('[│┃]')), b = text.lastIndexOf(RegExp('[│┃]'));
  if (a < 0 || b <= a) return runs;
  var from = a + 1, to = b;
  if (from < to && text[from] == ' ') from++;
  while (to > from && text[to - 1] == ' ') {
    to--;
  }
  final out = <Run>[];
  var pos = 0;
  for (final r in runs) {
    final s = pos, e = pos + r.text.length;
    pos = e;
    final lo = s > from ? s : from, hi = e < to ? e : to;
    if (lo < hi) out.add(r.withText(r.text.substring(lo - s, hi - s)));
  }
  return out;
}

/// The native "virtual screen": the chat's text laid out by the phone. Rotating, resizing or
/// pinch-zooming only re-wraps it here; the real tmux window on the PC never changes size.
class ReaderView extends StatefulWidget {
  final List<String> lines;
  final int width;
  final bool join;
  final Skin skin;
  final double fontSize;
  final ValueChanged<double> onZoom;
  const ReaderView(
      {super.key,
      required this.lines,
      required this.width,
      required this.join,
      required this.skin,
      required this.fontSize,
      required this.onZoom});

  @override
  State<ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends State<ReaderView> {
  final scroll = ScrollController();
  final _cache = <String, List<Run>>{};
  final _pointers = <int, Offset>{};
  double? _pinchStart, _fontStart;
  bool _atBottom = true;

  // the blocks only change with the content: don't rebuild them on every setState (pinch, FAB, skin...)
  List<Block>? _blocks;
  List<String>? _forLines;
  int? _forWidth;
  bool? _forJoin;

  @override
  void initState() {
    super.initState();
    scroll.addListener(() {
      if (!scroll.hasClients) return;
      final b = scroll.offset >= scroll.position.maxScrollExtent - 60;
      if (b != _atBottom) setState(() => _atBottom = b);
    });
    // start at the newest (bottom)
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom(instant: true));
  }

  @override
  void didUpdateWidget(ReaderView old) {
    super.didUpdateWidget(old);
    // new text: stay pinned to the newest only if we were already there; scrolled-up readers keep their place
    if (!identical(old.lines, widget.lines) && _atBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _toBottom(instant: true);
      });
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  void _toBottom({bool instant = false}) {
    if (!scroll.hasClients) return;
    final m = scroll.position.maxScrollExtent;
    if (instant) {
      scroll.jumpTo(m);
    } else {
      scroll.animateTo(m, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  List<Block> _blocksNow(TerminalTheme t) {
    if (_blocks != null && identical(_forLines, widget.lines) && _forWidth == widget.width && _forJoin == widget.join) {
      return _blocks!;
    }
    if (_cache.length > 60000) _cache.clear();
    _blocks = buildBlocks(widget.lines, widget.width, widget.join, t, _cache);
    _forLines = widget.lines;
    _forWidth = widget.width;
    _forJoin = widget.join;
    return _blocks!;
  }

  double? _spread() {
    if (_pointers.length < 2) return null;
    final p = _pointers.values.take(2).toList();
    return (p[0] - p[1]).distance;
  }

  TextSpan _span(List<Run> runs, TextStyle base) => TextSpan(style: base, children: [
        for (final r in runs)
          TextSpan(
            text: r.text,
            style: TextStyle(
              color: r.fg == null ? null : (r.dim ? r.fg!.withValues(alpha: 0.6) : r.fg),
              backgroundColor: r.bg,
              fontWeight: r.bold ? FontWeight.bold : null,
              fontStyle: r.italic ? FontStyle.italic : null,
              decoration: r.underline ? TextDecoration.underline : null,
            ).merge(r.dim && r.fg == null ? TextStyle(color: widget.skin.term.foreground.withValues(alpha: 0.6)) : null),
          ),
      ]);

  @override
  Widget build(BuildContext context) {
    final t = widget.skin.term;
    final blocks = _blocksNow(t);
    final base = TextStyle(
        color: t.foreground,
        fontSize: widget.fontSize,
        height: 1.3,
        fontFamily: widget.skin.termFont,
        fontFamilyFallback: const ['JetBrainsMono', 'monospace', 'Noto Color Emoji']);
    return Listener(
      onPointerDown: (e) {
        _pointers[e.pointer] = e.position;
        if (_pointers.length == 2) {
          _pinchStart = _spread();
          _fontStart = widget.fontSize;
        }
      },
      onPointerMove: (e) {
        _pointers[e.pointer] = e.position;
        final s = _spread();
        if (s != null && _pinchStart != null && _pinchStart! > 0) widget.onZoom(_fontStart! * s / _pinchStart!);
      },
      onPointerUp: (e) => _pointers.remove(e.pointer),
      onPointerCancel: (e) => _pointers.remove(e.pointer),
      child: Stack(children: [
        SelectionArea(
          child: ListView.builder(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            itemCount: blocks.length,
            itemBuilder: (context, i) {
              final b = blocks[i];
              return switch (b) {
                Rule() => Divider(height: widget.fontSize, thickness: 1, color: widget.skin.dim.withValues(alpha: 0.5)),
                Boxed(:final lines) => Container(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: widget.skin.dim.withValues(alpha: 0.6)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text.rich(TextSpan(children: [
                      for (var j = 0; j < lines.length; j++) ...[
                        if (j > 0) const TextSpan(text: '\n'),
                        _span(lines[j], base),
                      ],
                    ])),
                  ),
                Para(:final runs) => Text.rich(_span(runs, base)),
              };
            },
          ),
        ),
        if (!_atBottom)
          Positioned(
            right: 12,
            bottom: 12,
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: 'Jump to the newest',
              onPressed: _toBottom,
              child: const Icon(Icons.keyboard_double_arrow_down),
            ),
          ),
      ]),
    );
  }
}

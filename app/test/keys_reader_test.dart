import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/core/ansi.dart';
import 'package:switchboard/core/keys.dart';
import 'package:switchboard/skins/skins.dart';
import 'package:switchboard/widgets/extra_keys.dart';
import 'package:switchboard/widgets/reader_view.dart';

String text(Block b) => switch (b) {
      Para(:final runs) => runs.map((r) => r.text).join(),
      Boxed(:final lines) => lines.map((l) => l.map((r) => r.text).join()).join('|'),
      Rule() => '---',
    };

void main() {
  final t = skins.first.term;

  test('ctrl / alt encodings', () {
    expect(withMods('c', ctrl: true), '\x03');
    expect(withMods('L', ctrl: true), '\x0c');
    expect(withMods('[', ctrl: true), '\x1b');
    expect(withMods('b', alt: true), '\x1bb');
    expect(withMods('\r', alt: true), '\x1b\r');
    expect(withMods('\x1b[A', ctrl: true), '\x1b[1;5A');
    expect(withMods('\x1b[D', alt: true), '\x1b[1;3D');
    expect(withMods('\x1b[5~', ctrl: true), '\x1b[5;5~');
    expect(withMods('x'), 'x');
  });

  test('modifiers: tap = next key only, long-press = locked', () {
    final m = Modifiers();
    m.tap('ctrl');
    expect(m.apply('c'), '\x03');
    expect(m.apply('c'), 'c');
    m.lock('ctrl');
    expect(m.apply('a'), '\x01');
    expect(m.apply('e'), '\x05');
    m.tap('ctrl');
    expect(m.ctrl, ModState.off);
    m.tap('alt');
    m.tap('alt');
    expect(m.any, isFalse);
  });

  test('ansi colours and plain text', () {
    final runs = parseAnsi('\x1b[1;31mred\x1b[0m plain \x1b[38;2;1;2;3mrgb', t);
    expect(runs.map((r) => r.text).toList(), ['red', ' plain ', 'rgb']);
    expect(runs[0].bold, isTrue);
    expect(runs[0].fg, t.red);
    expect(runs[1].fg, isNull);
    expect(runs[2].fg, const Color.fromARGB(255, 1, 2, 3));
    expect(plain('\x1b[2mdim\x1b[22m'), 'dim');
  });

  test('reader blocks: rules, boxes, joined wrapped lines', () {
    final w = 40;
    final long = 'The quick brown fox jumps over the lazy'; // 39 chars: ran to the window edge
    final lines = [
      '● $long',
      '  dog and keeps running.',
      '',
      '  ⎿  a list item',
      '─' * 40,
      '╭──────────────╮',
      '│ > hello      │',
      '│   world      │',
      '╰──────────────╯',
      '- short line',
      'next line not joined',
    ];
    final b = buildBlocks(lines, w, true, t);
    expect(b.map(text).toList(), [
      '● $long dog and keeps running.',
      '',
      '  ⎿  a list item',
      '---',
      '> hello|  world',
      '- short line',
      'next line not joined',
    ]);
    // joining off keeps every line
    expect(buildBlocks(lines.take(2).toList(), w, false, t).length, 2);
  });

  testWidgets('extra keys: two full rows, CTRL then a key sends ctrl code', (tester) async {
    final sent = <String>[];
    final mods = Modifiers();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: ExtraKeys(skin: skins.first, mods: mods, onKey: sent.add))),
    ));
    for (final l in ['ESC', 'CTRL', 'ALT', '↑', '↓', '←', '→', '⏎', 'TAB', 'PGUP']) {
      expect(find.text(l), findsOneWidget);
    }
    await tester.tap(find.text('↑'));
    await tester.tap(find.text('⏎'));
    await tester.tap(find.text('CTRL'));
    await tester.pump();
    expect(mods.ctrl, ModState.once);
    await tester.tap(find.text('↓'));
    await tester.pump();
    expect(sent, ['\x1b[A', '\r', '\x1b[1;5B']);
    expect(mods.ctrl, ModState.off);
  });
}

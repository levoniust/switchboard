import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/skins/skins.dart';
import 'package:switchboard/widgets/reader_view.dart';

void main() {
  ReaderView view(List<String> lines) =>
      ReaderView(lines: lines, width: 80, join: false, skin: skins.first, fontSize: 14, onZoom: (_) {});

  ScrollPosition pos(WidgetTester tester) => tester
      .state<ScrollableState>(find.descendant(of: find.byType(ReaderView), matching: find.byType(Scrollable)))
      .position;

  Finder text(String s) => find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == s);

  Future<void> open(WidgetTester tester, List<String> lines) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: view(lines))));
    await tester.pump();
  }

  testWidgets('reader opens at the newest text and can scroll up through the whole history', (tester) async {
    await open(tester, List.generate(400, (i) => 'line $i'));
    expect(pos(tester).pixels, pos(tester).maxScrollExtent); // newest is on screen
    expect(text('line 399'), findsWidgets);
    expect(text('line 0'), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, 400)); // finger down = older
    await tester.pumpAndSettle();
    expect(pos(tester).pixels, lessThan(pos(tester).maxScrollExtent - 100));
    pos(tester).jumpTo(0); // the very first message of the chat is reachable
    await tester.pump();
    expect(text('line 0'), findsWidgets);
  });

  testWidgets('stays pinned to the newest while text streams in at the bottom', (tester) async {
    var lines = List.generate(300, (i) => 'a $i');
    await open(tester, lines);
    lines = [...lines, 'new 1', 'new 2'];
    await open(tester, lines);
    expect(pos(tester).pixels, pos(tester).maxScrollExtent);
    expect(text('new 2'), findsWidgets);
  });

  testWidgets('scrolled-up reading is not moved when new text arrives', (tester) async {
    var lines = List.generate(300, (i) => 'a $i');
    await open(tester, lines);
    pos(tester).jumpTo(1000); // read somewhere in the middle
    await tester.pump();
    lines = [...lines, ...List.generate(50, (i) => 'b $i')];
    await open(tester, lines);
    expect(pos(tester).pixels, 1000); // the viewport stays exactly where the reader left it
  });
}

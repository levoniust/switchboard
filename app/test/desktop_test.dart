import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:switchboard/core/hub.dart';
import 'package:switchboard/core/keys.dart';
import 'package:switchboard/core/platform.dart';
import 'package:switchboard/core/settings.dart';
import 'package:switchboard/main.dart';
import 'package:switchboard/screens/vigil_screen.dart';

void main() {
  tearDown(() => desktopOverride = null);

  test('focus sent to the bridge: a background window matches no chat, so the phone still gets pushed', () {
    expect(NodeLink.focusValue('%3', true), '%3');
    expect(NodeLink.focusValue(null, true), '*'); // app open, chat list on screen: banner instead of push
    expect(NodeLink.focusValue('%3', false), '-');
    expect(NodeLink.focusValue(null, false), '-');
  });

  test('extra keys bar: on by default on the phone, off on a computer, and the choice sticks', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final desktop in [false, true]) {
      desktopOverride = desktop;
      SharedPreferences.setMockInitialValues({});
      final s = Settings();
      await s.load();
      expect(s.extraKeys, !desktop);
      s.setExtraKeys(desktop);
      final again = Settings();
      await again.load();
      expect(again.extraKeys, desktop);
    }
  });

  testWidgets('Vigil on a computer offers the browser instead of a WebView', (tester) async {
    desktopOverride = true;
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() async {
      await settings.load(); // real I/O (asset manifest): outside the fake clock
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: VigilScreen())));
      await Future<void>.delayed(const Duration(milliseconds: 200)); // loopback proxy binds
    });
    await tester.pump();
    expect(find.textContaining('Vigil opens in your browser'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_browser), findsOneWidget);
    await tester.runAsync(LocalProxy.instance.close);
  });

  test('physical keyboard keys become terminal sequences', () {
    expect(hardwareKeySeq(LogicalKeyboardKey.escape), '\x1b');
    expect(hardwareKeySeq(LogicalKeyboardKey.tab), '\t');
    expect(hardwareKeySeq(LogicalKeyboardKey.tab, shift: true), '\x1b[Z');
    expect(hardwareKeySeq(LogicalKeyboardKey.arrowUp), '\x1b[A');
    expect(hardwareKeySeq(LogicalKeyboardKey.arrowLeft, ctrl: true), '\x1b[1;5D');
    expect(hardwareKeySeq(LogicalKeyboardKey.pageDown), '\x1b[6~');
    expect(hardwareKeySeq(LogicalKeyboardKey.enter, alt: true), '\x1b\r');
    expect(hardwareKeySeq(LogicalKeyboardKey.keyC, ctrl: true), '\x03');
    expect(hardwareKeySeq(LogicalKeyboardKey.keyR, ctrl: true), '\x12');
    expect(hardwareKeySeq(LogicalKeyboardKey.keyB, alt: true), '\x1bb');
    expect(hardwareKeySeq(LogicalKeyboardKey.keyV, ctrl: true), isNull); // paste
    expect(hardwareKeySeq(LogicalKeyboardKey.keyA), isNull); // plain typing goes through the text field
  });
}

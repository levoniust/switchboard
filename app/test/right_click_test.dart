// Right-click does what long-press does (mouse on Windows; touch keeps long-press).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/skins/chrome.dart';
import 'package:switchboard/skins/skins.dart';

void main() {
  for (final style in [SkinStyle.material1, SkinStyle.cli]) {
    testWidgets('SkinPanel: right-click and long-press run the same action ($style)', (t) async {
      final skin = skins.firstWhere((s) => s.style == style);
      var menus = 0;
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: SkinPanel(skin: skin, onTap: () {}, onLongPress: () => menus++, child: const Text('chat')))));
      await t.longPress(find.text('chat'));
      expect(menus, 1);
      await t.tap(find.text('chat'), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await t.pump();
      expect(menus, 2);
    });
  }
}

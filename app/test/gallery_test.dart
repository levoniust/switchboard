import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/core/settings.dart';
import 'package:switchboard/screens/skin_gallery_screen.dart';
import 'package:switchboard/skins/skins.dart';

void main() {
  Settings fake() => Settings()
    ..mikoAvailable = true
    ..assets = {
      'assets/private/miko/pro_idle.webp',
      'assets/private/miko/pro_done.webp',
      'assets/private/miko/pro_error.webp',
      'assets/private/miko/hood_idle.webp',
    }
    ..mikoLines = {
      'pro': {
        'done': ['{session} is done, Tim.'],
      },
    };

  test('mikoPictures lists only bundled pictures, in state order', () {
    final s = fake();
    expect(s.mikoPictures(MikoSet.pro).keys, ['idle', 'done', 'error']);
    expect(s.mikoPictures(MikoSet.hood).keys, ['idle']);
    expect(s.mikoPictures(MikoSet.lateNight), isEmpty);
  });

  testWidgets('gallery shows one tile per picture with its line', (tester) async {
    await tester.pumpWidget(MaterialApp(home: SkinGalleryScreen(skin: skinById('miko'), source: fake())));
    await tester.pump();
    expect(find.text('3 pictures'), findsOneWidget);
    expect(find.text('your chat is done, Tim.'), findsOneWidget);
    // no line for idle → falls back to when the picture shows
    expect(find.textContaining('chat is waiting for you'), findsOneWidget);
  });
}

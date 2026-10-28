import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../skins/skins.dart';

/// User preferences + what the build contains (the Miko skins exist only in the private build).
class Settings extends ChangeNotifier {
  late SharedPreferences _p;
  String skinId = 'cli';
  double fontSize = 13;
  double readerFontSize = 14;
  bool readerDefault = true; // chats open in the native Reader view (false = raw terminal)
  bool joinLines = true; // Reader: glue lines the CLI wrapped at its own width back into paragraphs
  bool haptics = true;
  bool appLock = false;
  bool mikoAvailable = false;
  Map<String, dynamic> mikoLines = {};
  Set<String> assets = {};

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      assets = manifest.listAssets().toSet();
    } catch (_) {}
    mikoAvailable = assets.contains('assets/private/miko/pro_idle.webp');
    if (assets.contains('assets/private/miko/lines.json')) {
      try {
        mikoLines = jsonDecode(await rootBundle.loadString('assets/private/miko/lines.json')) as Map<String, dynamic>;
      } catch (_) {}
    }
    skinId = _p.getString('skin') ?? 'cli';
    if (skin.isPrivate && !mikoAvailable) skinId = 'cli';
    fontSize = _p.getDouble('fontSize') ?? 13;
    haptics = _p.getBool('haptics') ?? true;
    readerFontSize = _p.getDouble('readerFontSize') ?? 14;
    readerDefault = _p.getBool('readerDefault') ?? true;
    joinLines = _p.getBool('joinLines') ?? true;
    appLock = _p.getBool('appLock') ?? false;
  }

  Skin get skin => skinById(skinId);
  List<Skin> get available => skins.where((s) => !s.isPrivate || mikoAvailable).toList();

  void setSkin(String id) {
    skinId = id;
    _p.setString('skin', id);
    notifyListeners();
  }

  void setFontSize(double v) {
    fontSize = v.clamp(8, 24);
    _p.setDouble('fontSize', fontSize);
    notifyListeners();
  }

  void setReaderFontSize(double v) {
    readerFontSize = v.clamp(9, 30);
    _p.setDouble('readerFontSize', readerFontSize);
    notifyListeners();
  }

  void setReaderDefault(bool v) {
    readerDefault = v;
    _p.setBool('readerDefault', v);
    notifyListeners();
  }

  void setJoinLines(bool v) {
    joinLines = v;
    _p.setBool('joinLines', v);
    notifyListeners();
  }

  void setHaptics(bool v) {
    haptics = v;
    _p.setBool('haptics', v);
    notifyListeners();
  }

  void setAppLock(bool v) {
    appLock = v;
    _p.setBool('appLock', v);
    notifyListeners();
  }

  /// Picture for the Miko mascot in [state] (idle/working/done/permission/question/error/sleep), or null.
  String? mikoImage(MikoSet set, String state) {
    final prefix = {MikoSet.pro: 'pro', MikoSet.hood: 'hood', MikoSet.chibi: 'chibi', MikoSet.chibiNight: 'chibinight', MikoSet.lateNight: 'latenight'}[set]!;
    final s = _mascotState(state);
    for (final cand in ['assets/private/miko/${prefix}_$s.webp', 'assets/private/miko/${prefix}_idle.webp']) {
      if (assets.contains(cand)) return cand;
    }
    return null;
  }

  /// One of Miko's lines for [state], in the voice of the skin's Miko set.
  String? mikoLine(MikoSet set, String state, {String session = 'that chat'}) {
    final voice = {MikoSet.pro: 'pro', MikoSet.hood: 'afterhours', MikoSet.chibi: 'chibi', MikoSet.chibiNight: 'chibi', MikoSet.lateNight: 'latenight'}[set]!;
    final list = ((mikoLines[voice] as Map?)?[_lineState(state)] as List?)?.cast<String>();
    if (list == null || list.isEmpty) return null;
    return list[Random().nextInt(list.length)].replaceAll('{session}', session);
  }

  static String _mascotState(String s) => const {
        'waiting': 'idle',
        'ended': 'sleep',
        'offline': 'error',
        'connecting': 'working',
      }[s] ??
      s;

  static String _lineState(String s) => const {'waiting': 'idle', 'ended': 'sleep', 'offline': 'disconnected'}[s] ?? s;
}

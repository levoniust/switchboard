import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_windows/flutter_local_notifications_windows.dart';

import 'hub.dart';

/// Computer-only extras: Windows toasts for alerts while the window is in the background, and bringing the
/// window to the front when one is clicked. Does nothing on the phone (HA push covers alerts there).
class Desktop {
  static final instance = Desktop._();
  Desktop._();

  static const _window = MethodChannel('switchboard/window');
  late final _toasts = FlutterLocalNotificationsWindows(); // opens its DLL: only ever touched on Windows
  bool _ready = false;

  /// Pane of the chat whose toast was clicked.
  final _clicks = StreamController<String?>.broadcast();
  Stream<String?> get clicks => _clicks.stream;

  Future<void> init() async {
    if (!Platform.isWindows || _ready) return;
    try {
      _ready = await _toasts.initialize(
        settings: const WindowsInitializationSettings(
          appName: 'Switchboard',
          appUserModelId: 'Levoniust.Switchboard',
          guid: '5f0b7c3e-1d2a-4c8e-9a61-3b9d2e7f4a10',
        ),
        onDidReceiveNotificationResponse: (r) {
          raise();
          _clicks.add(r.payload);
        },
      );
    } catch (_) {
      _ready = false; // no toasts, the in-app banner still works
    }
  }

  /// A toast for [a] (only called while the window is unfocused or minimized).
  Future<void> toast(Alert a) async {
    if (!_ready) return;
    final who = a.sessionName ?? 'Claude';
    try {
      await _toasts.show(
        id: a.id & 0x7fffffff,
        title: '$who: ${a.title}',
        body: a.body.isEmpty ? null : a.body,
        payload: '${a.node?.id ?? ''}|${a.pane ?? ''}',  // node|pane
      );
    } catch (_) {}
  }

  Future<void> raise() async {
    if (!Platform.isWindows) return;
    try {
      await _window.invokeMethod<void>('raise');
    } catch (_) {}
  }
}

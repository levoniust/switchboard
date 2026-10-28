import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../skins/chrome.dart';
import 'api.dart';

class Session {
  final String id, name, pane, cwd, kind, status, last;
  final String? model;
  final Alert? pending;
  final int index;

  Session.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        index = (j['index'] as num?)?.toInt() ?? 0,
        name = j['name'] as String? ?? '',
        pane = j['pane'] as String? ?? '',
        cwd = j['cwd'] as String? ?? '',
        kind = j['kind'] as String? ?? 'shell',
        status = j['status'] as String? ?? 'idle',
        last = j['last'] as String? ?? '',
        model = j['model'] as String?,
        pending = j['pending'] == null ? null : Alert.fromJson(j['pending'] as Map<String, dynamic>);

  String get shortCwd {
    final parts = cwd.split('/').where((p) => p.isNotEmpty).toList();
    return parts.length <= 2 ? cwd : '…/${parts.sublist(parts.length - 2).join('/')}';
  }

  bool get isClaude => kind == 'claude' || kind == 'claude-local';
}

class AlertOption {
  final String key, label, detail;
  AlertOption(this.key, this.label, [this.detail = '']);
}

class Alert {
  final int id;
  final double ts;
  final String? pane, window, sessionName, kind;
  final String type, title, body, state;
  final String? answered;
  final List<AlertOption> options;
  final List<AlertOption> screenOptions;

  Alert.fromJson(Map<String, dynamic> j)
      : id = (j['id'] as num).toInt(),
        ts = (j['ts'] as num?)?.toDouble() ?? 0,
        pane = j['pane'] as String?,
        window = j['window'] as String?,
        sessionName = j['session_name'] as String?,
        kind = j['kind'] as String?,
        type = j['type'] as String? ?? 'info',
        title = j['title'] as String? ?? '',
        body = j['body'] as String? ?? '',
        state = j['state'] as String? ?? 'open',
        answered = j['answered'] as String?,
        options = ((j['options'] as List?) ?? [])
            .map((o) => AlertOption('${o['key']}', '${o['label']}', '${o['detail'] ?? ''}'))
            .toList(),
        screenOptions = ((j['screen_options'] as List?) ?? [])
            .map((o) => AlertOption('${o['key']}', '${o['label']}'))
            .toList();

  bool get needsAnswer => state == 'open' && (type == 'permission' || type == 'question');
  DateTime get time => DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
}

enum LinkState { offline, connecting, online }

/// Live app state: sessions, alerts, connection. Keeps one events WebSocket open while the app runs and
/// reconnects with backoff (network switches between home Wi-Fi and Tailscale are expected).
class Hub extends ChangeNotifier {
  Api? api;
  Server? server;
  List<Session> sessions = [];
  List<Alert> alerts = [];
  LinkState link = LinkState.offline;
  String? error;
  final _alertCtrl = StreamController<Alert>.broadcast();
  Stream<Alert> get newAlerts => _alertCtrl.stream;

  WebSocket? _ws;
  Timer? _retry;
  int _backoff = 1;
  bool _paused = false;
  String? _focusPane;

  Future<void> start(Server s) async {
    server = s;
    promptHost = s.name.toLowerCase();
    api = Api(s);
    _paused = false; // a new pairing starts fresh, even right after "Forget"
    await connect();
  }

  Future<void> connect() async {
    if (api == null || _paused) return;
    _retry?.cancel();
    _ws?.close(); // never keep two event sockets (each would deliver every alert)
    _ws = null;
    link = LinkState.connecting;
    notifyListeners();
    try {
      api!.activeHost = null;
      await refresh();
      final ws = await api!.socket('/api/events');
      if (_paused) {
        ws.close(); // the app went to the background while we were connecting
        return;
      }
      _ws = ws;
      link = LinkState.online;
      error = null;
      _backoff = 1;
      notifyListeners();
      setFocus(_focusPane);
      // only the current socket's end counts: an old socket closing must not drop the live one
      ws.listen(_onEvent, onDone: () {
        if (_ws == ws) _lost();
      }, onError: (_) {
        if (_ws == ws) _lost();
      }, cancelOnError: true);
    } catch (e) {
      error = '$e';
      _lost();
    }
  }

  void _lost() {
    _ws = null;
    if (link != LinkState.offline) {
      link = LinkState.offline;
      notifyListeners();
    }
    if (_paused) return;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: _backoff), connect);
    _backoff = (_backoff * 2).clamp(1, 30);
  }

  /// App went to background: close the socket (Android would freeze it anyway; HA push covers alerts).
  void pause() {
    _paused = true;
    _retry?.cancel();
    _ws?.close();
    _ws = null;
    link = LinkState.offline;
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    connect();
  }

  Future<void> refresh() async {
    if (api == null) return;
    final s = await api!.get('/api/sessions') as List;
    sessions = s.map((j) => Session.fromJson(j as Map<String, dynamic>)).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final a = await api!.get('/api/alerts') as List;
    alerts = a.map((j) => Alert.fromJson(j as Map<String, dynamic>)).toList();
    notifyListeners();
  }

  void _onEvent(dynamic data) {
    if (data is! String) return;
    final m = jsonDecode(data) as Map<String, dynamic>;
    switch (m['type']) {
      case 'alert':
        final a = Alert.fromJson(m['alert'] as Map<String, dynamic>);
        alerts.insert(0, a);
        _alertCtrl.add(a);
        refresh().ignore();
        break;
      case 'status':
      case 'sessions':
      case 'alert_closed':
        refresh().ignore(); // a failed refresh is retried by the next event or reconnect
        break;
    }
  }

  /// Tells the bridge which chat is on screen, so it doesn't push a phone notification for it.
  void setFocus(String? pane) {
    _focusPane = pane;
    // '*' = the app is open but no chat is on screen: the bridge still skips phone push (we show a banner instead)
    _ws?.add(jsonEncode({'type': 'focus', 'pane': pane ?? '*'}));
  }

  Session? sessionByPane(String? pane) {
    for (final s in sessions) {
      if (s.pane == pane) return s;
    }
    return null;
  }

  Session? sessionById(String id) {
    for (final s in sessions) {
      if (s.id == id || s.pane == id) return s;
    }
    return null;
  }

  int get openCount => alerts.where((a) => a.needsAnswer).length;

  Future<Alert> alert(int id) async =>
      Alert.fromJson(await api!.get('/api/alerts/$id') as Map<String, dynamic>);

  Future<String> answer(int id, String key) async {
    final r = await api!.post('/api/alerts/$id/answer', {'key': key}) as Map;
    await refresh();
    return '${r['answered']}';
  }

  Future<void> sendKeys(Session s, {List<String> keys = const [], String? text}) =>
      api!.post('/api/sessions/${Uri.encodeComponent(s.id)}/keys', {'keys': keys, 'text': ?text});

  Future<String> newSession(String kind, String cwd, String name) async {
    final r = await api!.post('/api/sessions', {'kind': kind, 'cwd': cwd, 'name': name}) as Map;
    await refresh();
    return r['id'] as String;
  }

  Future<void> rename(Session s, String name) async {
    await api!.post('/api/sessions/${Uri.encodeComponent(s.id)}/rename', {'name': name});
    await refresh();
  }

  Future<void> kill(Session s) async {
    await api!.delete('/api/sessions/${Uri.encodeComponent(s.id)}');
    await refresh();
  }

  @override
  void dispose() {
    _retry?.cancel();
    _ws?.close();
    _alertCtrl.close();
    super.dispose();
  }
}

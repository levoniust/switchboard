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

  /// The machine this chat runs on (null only in tests).
  final NodeLink? node;

  Session.fromJson(Map<String, dynamic> j, [this.node])
      : id = j['id'] as String,
        index = (j['index'] as num?)?.toInt() ?? 0,
        name = j['name'] as String? ?? '',
        pane = j['pane'] as String? ?? '',
        cwd = j['cwd'] as String? ?? '',
        kind = j['kind'] as String? ?? 'shell',
        status = j['status'] as String? ?? 'idle',
        last = j['last'] as String? ?? '',
        model = j['model'] as String?,
        pending = j['pending'] == null ? null : Alert.fromJson(j['pending'] as Map<String, dynamic>, node);

  String get shortCwd {
    final sep = cwd.contains('\\') ? '\\' : '/';
    final parts = cwd.split(sep).where((p) => p.isNotEmpty).toList();
    return parts.length <= 2 ? cwd : '…$sep${parts.sublist(parts.length - 2).join(sep)}';
  }

  bool get isClaude => (node ?? hub0)?.launcher(kind).claude ?? kind != 'shell';

  /// Unique across machines (ids and panes are only unique within one machine).
  String get key => '${node?.id ?? ''}|$id';
}

/// One entry of the bridge's "new chat" menu (GET /api/info "launchers"). The bridge owner names them
/// (config.json "launchers"); older bridges send none, so the app falls back to [Launcher.defaults].
class Launcher {
  final String kind, label, name, icon;
  final bool claude;
  final int accent;
  const Launcher(this.kind, this.label, this.name, {this.claude = true, this.accent = 1, this.icon = 'chip'});

  Launcher.fromJson(Map<String, dynamic> j)
      : kind = j['kind'] as String,
        label = j['label'] as String? ?? j['kind'] as String,
        name = j['name'] as String? ?? j['kind'] as String,
        claude = j['claude'] as bool? ?? j['kind'] != 'shell',
        accent = (j['accent'] as num?)?.toInt() == 2 ? 2 : 1,
        icon = j['icon'] as String? ?? 'chip';

  static const defaults = [
    Launcher('claude', 'Claude', 'claude', icon: 'cloud'),
    Launcher('claude-local', 'Local', 'local', accent: 2),
    Launcher('shell', 'Shell', 'shell', claude: false, icon: 'terminal'),
  ];
}

/// The last [NodeLink] created: lets a [Session] without a machine (tests) still find launchers.
NodeLink? hub0;

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
  final NodeLink? node;

  Alert.fromJson(Map<String, dynamic> j, [this.node])
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

/// One machine: its sessions, alerts and connection. Keeps one events WebSocket open while the app runs and
/// reconnects with backoff (network switches between home Wi-Fi and Tailscale are expected).
class NodeLink extends ChangeNotifier {
  NodeLink([Server? s]) {
    hub0 = this;
    if (s != null) {
      server = s;
      api = Api(s);
    }
  }

  /// Node id, or (old bridges) a stand-in made from the certificate pin.
  String get id => server?.id ?? 'pin:${server?.pin.substring(0, 12) ?? ''}';
  String get name => server?.name ?? '';
  String os = 'linux';
  bool vigil = false;
  List<String> features = [];
  String sep = '/';

  Api? api;
  List<Launcher> launchers = Launcher.defaults;
  bool _launchersLoaded = false;

  Launcher launcher(String kind) => launchers.firstWhere((l) => l.kind == kind,
      orElse: () => Launcher(kind, kind, kind, claude: kind != 'shell'));
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
  bool _windowActive = true;

  /// Desktop: false while the window is unfocused or minimized. The socket stays open (alerts become Windows
  /// toasts), but the bridge is told nobody is looking, so the phone still gets its push.
  bool get windowActive => _windowActive;
  void setWindowActive(bool v) {
    if (v == _windowActive) return;
    _windowActive = v;
    setFocus(_focusPane);
  }

  Future<void> start(Server s) async {
    server = s;
    launchers = Launcher.defaults;
    _launchersLoaded = false;
    api = Api(s);
    _paused = false; // a new pairing starts fresh, even right after "Forget"
    await connect();
  }

  /// Called when /api/info reveals the node id of a machine paired with an old (v1) link.
  void Function(NodeLink)? onIdentified;

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
    if (!_launchersLoaded) {
      try {
        final info = await api!.get('/api/info') as Map;
        os = info['os'] as String? ?? 'linux';
        sep = os == 'windows' ? '\\' : '/';
        vigil = info['vigil'] == true;
        features = ((info['features'] as List?) ?? const []).cast<String>();
        final nid = info['node_id'] as String?;
        if (nid != null && server != null && server!.id != nid) {
          server = server!.copyWith(id: nid);
          onIdentified?.call(this);
        }
        final ls = info['launchers'] as List?;
        if (ls != null && ls.isNotEmpty) {
          launchers = ls.map((j) => Launcher.fromJson(j as Map<String, dynamic>)).toList();
        }
        _launchersLoaded = true;
      } catch (_) {} // older bridge or a blip: keep the defaults, try again next refresh
    }
    final s = await api!.get('/api/sessions') as List;
    sessions = s.map((j) => Session.fromJson(j as Map<String, dynamic>, this)).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final a = await api!.get('/api/alerts') as List;
    alerts = a.map((j) => Alert.fromJson(j as Map<String, dynamic>, this)).toList();
    notifyListeners();
  }

  void _onEvent(dynamic data) {
    if (data is! String) return;
    final m = jsonDecode(data) as Map<String, dynamic>;
    switch (m['type']) {
      case 'alert':
        final a = Alert.fromJson(m['alert'] as Map<String, dynamic>, this);
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
    // '*' = the app is open but no chat is on screen: the bridge still skips phone push (we show a banner instead).
    // '-' = a desktop window in the background: matches no chat, so the bridge pushes the phone as usual.
    _ws?.add(jsonEncode({'type': 'focus', 'pane': focusValue(pane, _windowActive)}));
  }

  static String focusValue(String? pane, bool windowActive) => windowActive ? pane ?? '*' : '-';

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
      Alert.fromJson(await api!.get('/api/alerts/$id') as Map<String, dynamic>, this);

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
    _paused = true;
    _retry?.cancel();
    _ws?.close();
    _alertCtrl.close();
    super.dispose();
  }
}

/// Every paired machine at once: the app's view merges their chats and alerts. Each [NodeLink] connects on its
/// own, so one machine being off never affects the others.
class Fleet extends ChangeNotifier {
  final List<NodeLink> nodes = [];
  final _alertCtrl = StreamController<Alert>.broadcast();
  final _subs = <NodeLink, StreamSubscription<Alert>>{};
  Stream<Alert> get newAlerts => _alertCtrl.stream;
  bool _windowActive = true;
  Session? _focus;

  bool get paired => nodes.isNotEmpty;

  Future<void> start(List<Server> servers) async {
    for (final s in servers) {
      _attach(NodeLink());
      nodes.last.server = s;
    }
    _sortForPrompt();
    notifyListeners();
    await Future.wait(nodes.map((n) => n.start(n.server!)));
  }

  void _attach(NodeLink n) {
    nodes.add(n);
    n.addListener(notifyListeners);
    n.onIdentified = (_) => _save();
    _subs[n] = n.newAlerts.listen(_alertCtrl.add);
  }

  void _sortForPrompt() => promptHost = nodes.isEmpty ? 'switchboard' : nodes.first.name.toLowerCase();

  Future<void> _save() => Server.saveAll([for (final n in nodes) if (n.server != null) n.server!]);

  /// Adds a newly paired machine, or replaces the entry of the same machine (re-pairing).
  Future<NodeLink> add(Server s) async {
    final old = nodes.where((n) => n.server != null && n.server!.sameMachine(s)).toList();
    for (final n in old) {
      _detach(n);
    }
    final n = NodeLink()..server = s;
    _attach(n);
    await _save();
    _sortForPrompt();
    notifyListeners();
    await n.start(s);
    return n;
  }

  void _detach(NodeLink n) {
    nodes.remove(n);
    n.removeListener(notifyListeners);
    _subs.remove(n)?.cancel();
    n.dispose();
  }

  /// Forgets a machine: tells it to revoke this device's key (best effort), then drops it here.
  Future<void> remove(NodeLink n) async {
    try {
      final r = await n.api?.get('/api/devices') as Map?;
      final me = r?['you'] as String?;
      if (me != null && me != 'legacy') await n.api!.delete('/api/devices/$me');
    } catch (_) {} // offline machine: its key stays valid until revoked there (switchboard devices revoke)
    _detach(n);
    await _save();
    _sortForPrompt();
    notifyListeners();
  }

  NodeLink? node(String? id) {
    if (nodes.isEmpty) return null;
    if (id == null || id.isEmpty) return nodes.first; // links from old pushes: the first machine
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  List<Session> get sessions => [for (final n in nodes) ...n.sessions];

  List<Alert> get alerts => [for (final n in nodes) ...n.alerts]..sort((a, b) => b.ts.compareTo(a.ts));

  int get openCount => nodes.fold(0, (sum, n) => sum + n.openCount);

  /// online if any machine is, connecting if any is trying, else offline.
  LinkState get link => nodes.any((n) => n.link == LinkState.online)
      ? LinkState.online
      : nodes.any((n) => n.link == LinkState.connecting)
          ? LinkState.connecting
          : LinkState.offline;

  /// The machine that serves Vigil (the first that says it can).
  NodeLink? get vigilNode {
    for (final n in nodes) {
      if (n.vigil) return n;
    }
    return nodes.isEmpty ? null : nodes.first;
  }

  Future<void> connect() => Future.wait(nodes.map((n) => n.connect()));
  Future<void> refresh() => Future.wait(nodes.map((n) => n.refresh().catchError((_) {})));
  void pause() {
    for (final n in nodes) {
      n.pause();
    }
  }

  void resume() {
    for (final n in nodes) {
      n.resume();
    }
  }

  bool get windowActive => _windowActive;
  void setWindowActive(bool v) {
    _windowActive = v;
    for (final n in nodes) {
      n.setWindowActive(v);
    }
  }

  /// The chat on screen (null = the lists). Its machine is told that pane; the others just "app open".
  void setFocus(Session? s) {
    _focus = s;
    for (final n in nodes) {
      n.setFocus(s != null && s.node == n ? s.pane : null);
    }
  }

  Session? get focused => _focus;

  Session? sessionByPane(String? pane, [String? nodeId]) {
    final n = node(nodeId);
    if (nodeId != null && n != null) return n.sessionByPane(pane);
    for (final x in nodes) {
      final s = x.sessionByPane(pane);
      if (s != null) return s;
    }
    return null;
  }

  Session? sessionById(String id, [String? nodeId]) {
    if (nodeId != null) return node(nodeId)?.sessionById(id);
    for (final x in nodes) {
      final s = x.sessionById(id);
      if (s != null) return s;
    }
    return null;
  }

  /// The session an alert belongs to (same machine, same pane).
  Session? sessionFor(Alert a) => a.node?.sessionByPane(a.pane) ?? sessionByPane(a.pane);

  Future<String> answer(Alert a, String key) => (a.node ?? nodes.first).answer(a.id, key);

  @override
  void dispose() {
    for (final n in List.of(nodes)) {
      _detach(n);
    }
    _alertCtrl.close();
    super.dispose();
  }
}

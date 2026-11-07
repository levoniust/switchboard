import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One paired machine (node): hosts to try in order (LAN first, then Tailscale), port, this device's token, cert pin.
/// [id] is the node's id (proto 2); links from old bridges have none until /api/info tells us.
/// [code] is the one-time pairing code of a v2 link: it is traded for [token] once and never saved.
class Server {
  final String name;
  final List<String> hosts;
  final int port;
  final String token;
  final String pin; // sha256 of the bridge certificate (DER), hex
  final String? id;
  final String? code;

  const Server({required this.name, required this.hosts, required this.port, required this.token, required this.pin,
      this.id, this.code});

  Server copyWith({String? name, String? token, String? id}) => Server(
      name: name ?? this.name, hosts: hosts, port: port, token: token ?? this.token, pin: pin, id: id ?? this.id);

  Map<String, dynamic> toJson() => {'n': name, 'h': hosts, 'p': port, 't': token, 'c': pin, 'id': ?id};

  factory Server.fromJson(Map<String, dynamic> j) => Server(
        name: j['n'] as String? ?? 'bridge',
        hosts: (j['h'] as List).cast<String>(),
        port: (j['p'] as num).toInt(),
        token: j['t'] as String? ?? '',
        pin: (j['c'] as String).toLowerCase(),
        id: j['id'] as String?,
        code: j['k'] as String?,
      );

  /// Parses the `switchboard://pair/<base64url json>` link (or just the payload): v1 carries the shared token,
  /// v2 a one-time code to trade for this device's own token.
  static Server? fromPairLink(String link) {
    var payload = link.trim();
    final i = payload.indexOf('pair/');
    if (i >= 0) payload = payload.substring(i + 5);
    payload = payload.split('?').first;
    try {
      final norm = base64Url.normalize(payload);
      final s = Server.fromJson(jsonDecode(utf8.decode(base64Url.decode(norm))) as Map<String, dynamic>);
      return s.token.isEmpty && s.code == null ? null : s;
    } catch (_) {
      return null;
    }
  }

  /// Same machine: same node id, or (old bridges without one) same addresses and certificate.
  bool sameMachine(Server o) => id != null && o.id != null ? id == o.id : pin == o.pin && port == o.port;

  static const _storage = FlutterSecureStorage();

  /// All paired machines. Moves an old single 'server' entry into the list on first run.
  static Future<List<Server>> loadAll() async {
    final raw = await _storage.read(key: 'servers');
    if (raw != null) {
      return (jsonDecode(raw) as List).map((j) => Server.fromJson(j as Map<String, dynamic>)).toList();
    }
    final old = await _storage.read(key: 'server');
    if (old == null) return [];
    final list = [Server.fromJson(jsonDecode(old) as Map<String, dynamic>)];
    await saveAll(list);
    await _storage.delete(key: 'server');
    return list;
  }

  static Future<void> saveAll(List<Server> list) =>
      _storage.write(key: 'servers', value: jsonEncode(list.map((s) => s.toJson()).toList()));
}

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => message;
}

/// REST + WebSocket client for the bridge, with certificate pinning and LAN/Tailscale fallback.
class Api {
  final Server server;
  String? activeHost;
  late final HttpClient _http;

  Api(this.server) {
    _http = pinnedClient(server.pin);
  }

  static HttpClient pinnedClient(String pin) {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..idleTimeout = const Duration(seconds: 20);
    // The bridge uses a self-signed certificate; we trust exactly that certificate (its SHA-256), nothing else.
    c.badCertificateCallback = (X509Certificate cert, String host, int port) =>
        sha256.convert(cert.der).toString() == pin;
    return c;
  }

  String get _base => 'https://${activeHost ?? server.hosts.first}:${server.port}';

  /// Picks the first host that answers /health (LAN when home, Tailscale when away).
  Future<String?> probe() async {
    final results = await Future.wait(server.hosts.map((h) async {
      try {
        final req = await _http.getUrl(Uri.parse('https://$h:${server.port}/health')).timeout(const Duration(seconds: 3));
        final res = await req.close().timeout(const Duration(seconds: 3));
        await res.drain<void>();
        return res.statusCode == 200 ? h : null;
      } catch (_) {
        return null;
      }
    }));
    // keep the configured order: the first reachable host wins
    for (var i = 0; i < server.hosts.length; i++) {
      if (results[i] != null) return activeHost = results[i];
    }
    return null;
  }

  Future<dynamic> _send(String method, String path, {Object? body, Map<String, String>? query}) async {
    activeHost ??= await probe();
    if (activeHost == null) throw ApiException(0, 'Bridge not reachable (LAN or Tailscale)');
    final uri = Uri.parse('$_base$path').replace(queryParameters: query);
    try {
      final req = await _http.openUrl(method, uri).timeout(const Duration(seconds: 6));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${server.token}');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(const Duration(seconds: 15));
      final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) {
        String msg = text;
        try {
          msg = (jsonDecode(text) as Map)['error']?.toString() ?? text;
        } catch (_) {}
        throw ApiException(res.statusCode, msg.isEmpty ? 'HTTP ${res.statusCode}' : msg);
      }
      return text.isEmpty ? null : jsonDecode(text);
    } on SocketException {
      activeHost = null; // network changed (home <-> away): probe again next time
      rethrow;
    } on TimeoutException {
      activeHost = null;
      rethrow;
    }
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) => _send('GET', path, query: query);
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body: body ?? {});
  Future<dynamic> delete(String path) => _send('DELETE', path);

  Future<WebSocket> socket(String path, {Map<String, String>? query}) async {
    activeHost ??= await probe();
    if (activeHost == null) throw ApiException(0, 'Bridge not reachable (LAN or Tailscale)');
    final uri = Uri.parse('wss://$activeHost:${server.port}$path').replace(queryParameters: query);
    try {
      final ws = await WebSocket.connect(uri.toString(),
              headers: {HttpHeaders.authorizationHeader: 'Bearer ${server.token}'}, customClient: _http)
          .timeout(const Duration(seconds: 8));
      ws.pingInterval = const Duration(seconds: 20);
      return ws;
    } on SocketException {
      activeHost = null; // network changed (home <-> away): probe again next time
      rethrow;
    } on TimeoutException {
      activeHost = null;
      rethrow;
    }
  }

  Future<String> upload(String filename, Uint8List bytes) async {
    activeHost ??= await probe();
    if (activeHost == null) throw ApiException(0, 'Bridge not reachable (LAN or Tailscale)');
    final safeName = filename.replaceAll(RegExp(r'["\r\n\\]'), '_');
    final boundary = 'sb${DateTime.now().microsecondsSinceEpoch}';
    final req = await _http.postUrl(Uri.parse('$_base/api/upload')).timeout(const Duration(seconds: 6));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${server.token}');
    req.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');
    req.add(utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="file"; filename="$safeName"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n'));
    req.add(bytes);
    req.add(utf8.encode('\r\n--$boundary--\r\n'));
    final res = await req.close().timeout(const Duration(seconds: 120));
    final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
    if (res.statusCode >= 400) throw ApiException(res.statusCode, text);
    return (jsonDecode(text) as Map)['path'] as String;
  }

  /// Trades a v2 link's one-time code for this device's own token. Returns the server to save.
  Future<Server> redeem(String deviceName) async {
    final r = await post('/api/pair', {'code': server.code, 'device': deviceName}) as Map;
    return server.copyWith(token: r['token'] as String, id: r['node_id'] as String?, name: r['name'] as String?);
  }

  String vigilUrl() => '$_base/vigil/?token=${Uri.encodeComponent(server.token)}';
}

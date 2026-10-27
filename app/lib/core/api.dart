import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One paired bridge: hosts to try in order (LAN first, then Tailscale), port, token, certificate pin.
class Server {
  final String name;
  final List<String> hosts;
  final int port;
  final String token;
  final String pin; // sha256 of the bridge certificate (DER), hex

  const Server({required this.name, required this.hosts, required this.port, required this.token, required this.pin});

  Map<String, dynamic> toJson() => {'n': name, 'h': hosts, 'p': port, 't': token, 'c': pin};

  factory Server.fromJson(Map<String, dynamic> j) => Server(
        name: j['n'] as String? ?? 'bridge',
        hosts: (j['h'] as List).cast<String>(),
        port: (j['p'] as num).toInt(),
        token: j['t'] as String,
        pin: (j['c'] as String).toLowerCase(),
      );

  /// Parses the `switchboard://pair/<base64url json>` link (or just the payload).
  static Server? fromPairLink(String link) {
    var payload = link.trim();
    final i = payload.indexOf('pair/');
    if (i >= 0) payload = payload.substring(i + 5);
    payload = payload.split('?').first;
    try {
      final norm = base64Url.normalize(payload);
      return Server.fromJson(jsonDecode(utf8.decode(base64Url.decode(norm))) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static const _storage = FlutterSecureStorage();

  static Future<Server?> load() async {
    final s = await _storage.read(key: 'server');
    return s == null ? null : Server.fromJson(jsonDecode(s) as Map<String, dynamic>);
  }

  Future<void> save() => _storage.write(key: 'server', value: jsonEncode(toJson()));

  static Future<void> forget() => _storage.delete(key: 'server');
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
      final text = await res.transform(utf8.decoder).join();
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
    final ws = await WebSocket.connect(uri.toString(),
            headers: {HttpHeaders.authorizationHeader: 'Bearer ${server.token}'}, customClient: _http)
        .timeout(const Duration(seconds: 8));
    ws.pingInterval = const Duration(seconds: 20);
    return ws;
  }

  Future<String> upload(String filename, Uint8List bytes) async {
    activeHost ??= await probe();
    final boundary = 'sb${DateTime.now().microsecondsSinceEpoch}';
    final req = await _http.postUrl(Uri.parse('$_base/api/upload'));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${server.token}');
    req.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');
    req.add(utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="file"; filename="$filename"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n'));
    req.add(bytes);
    req.add(utf8.encode('\r\n--$boundary--\r\n'));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) throw ApiException(res.statusCode, text);
    return (jsonDecode(text) as Map)['path'] as String;
  }

  String vigilUrl() => '$_base/vigil/?token=${Uri.encodeComponent(server.token)}';
}

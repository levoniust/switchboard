import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/api.dart';
import '../main.dart';
import '../skins/chrome.dart';

/// Vigil (the homelab watchtower) through the bridge, so it works away from home too.
/// Android's WebView won't trust the bridge's self-signed certificate, so the app runs a tiny proxy on
/// 127.0.0.1 that forwards to the bridge over the pinned connection and adds the access key.
class VigilScreen extends StatefulWidget {
  final bool standalone;
  const VigilScreen({super.key, this.standalone = false});
  @override
  State<VigilScreen> createState() => _VigilScreenState();
}

class _VigilScreenState extends State<VigilScreen> {
  WebViewController? _web;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final port = await LocalProxy.instance.ensure();
      final c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(settings.skin.bg)
        ..loadRequest(Uri.parse('http://127.0.0.1:$port/vigil/'));
      setState(() => _web = c);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final skin = settings.skin;
    final body = Column(children: [
      SkinHeader(skin: skin, title: 'Vigil', subtitle: 'homelab watchtower', actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: () => _web?.reload()),
      ]),
      Expanded(
        child: _web != null
            ? WebViewWidget(controller: _web!)
            : Center(child: Text(_error ?? 'Starting…', style: TextStyle(color: skin.dim))),
      ),
    ]);
    if (!widget.standalone) return body;
    return Scaffold(body: SkinBackground(skin: skin, child: body));
  }
}

/// Loopback HTTP proxy → bridge (pinned TLS + bearer token). Only serves /vigil/ paths.
class LocalProxy {
  static final instance = LocalProxy._();
  LocalProxy._();
  HttpServer? _server;

  Future<int> ensure() async {
    if (_server != null) return _server!.port;
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = s;
    s.listen(_handle);
    return s.port;
  }

  Future<void> _handle(HttpRequest req) async {
    final api = hub.api;
    // only Vigil's pages go through (with the token): no "..", plain or %-encoded, to climb out to the bridge API
    final raw = req.uri.path.toLowerCase();
    if (api == null || !raw.startsWith('/vigil/') || raw.contains('..') || raw.contains('%2e')) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    try {
      api.activeHost ??= await api.probe();
      final client = Api.pinnedClient(api.server.pin);
      final target = Uri.parse('https://${api.activeHost}:${api.server.port}${req.uri}');
      final out = await client.openUrl(req.method, target);
      out.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${api.server.token}');
      final ct = req.headers.contentType;
      if (ct != null) out.headers.contentType = ct;
      await out.addStream(req);
      final res = await out.close().timeout(const Duration(seconds: 30));
      req.response.statusCode = res.statusCode;
      res.headers.forEach((name, values) {
        if (const ['content-type', 'cache-control', 'location'].contains(name)) {
          req.response.headers.set(name, values.join(','));
        }
      });
      await req.response.addStream(res);
      client.close();
    } catch (e) {
      req.response.statusCode = 502;
      req.response.write('Vigil is not reachable through the bridge: $e');
    }
    await req.response.close();
  }
}

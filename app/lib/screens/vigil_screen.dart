import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/api.dart';
import '../core/platform.dart';
import '../main.dart';
import '../skins/chrome.dart';
import '../skins/skins.dart';

/// Vigil (the homelab watchtower) through the bridge, so it works away from home too.
/// Android's WebView won't trust the bridge's self-signed certificate, so the app runs a tiny proxy on
/// 127.0.0.1 that forwards to the bridge over the pinned connection and adds the access key.
/// On a computer there is no WebView: the same proxy is opened in the default browser.
class VigilScreen extends StatefulWidget {
  final bool standalone;
  const VigilScreen({super.key, this.standalone = false});
  @override
  State<VigilScreen> createState() => _VigilScreenState();
}

class _VigilScreenState extends State<VigilScreen> {
  WebViewController? _web;
  int? _port; // desktop: the proxy is ready
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final port = await LocalProxy.instance.ensure();
      if (isDesktop) {
        setState(() => _port = port);
        return;
      }
      final c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(settings.skin.bg)
        ..setNavigationDelegate(NavigationDelegate(onNavigationRequest: _onNavigation))
        ..loadRequest(Uri.parse('http://127.0.0.1:$port/vigil/'));
      setState(() => _web = c);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _openInBrowser() async {
    if (_port == null) return;
    final ok = await launchUrl(Uri.parse('http://127.0.0.1:$_port/vigil/'), mode: LaunchMode.externalApplication);
    if (!ok) toast('Could not open the browser');
  }

  Widget _desktopBody(Skin skin) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error ?? (_port == null ? 'Starting…' : 'Vigil opens in your browser, through this app.'),
              style: TextStyle(color: skin.dim)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _port == null ? null : _openInBrowser,
            icon: const Icon(Icons.open_in_browser),
            label: Text(skin.head('Open Vigil')),
          ),
          const SizedBox(height: 8),
          Text('The page works while Switchboard is running.', style: TextStyle(color: skin.dim, fontSize: 12)),
        ]),
      );

  /// Vigil itself stays in the WebView; its links to lab services (plain http on the home network, reachable away
  /// from home over Tailscale's subnet route) open in the phone's browser: the WebView refuses cleartext pages.
  NavigationDecision _onNavigation(NavigationRequest req) {
    final uri = Uri.tryParse(req.url);
    if (uri == null || uri.host == '127.0.0.1' || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return NavigationDecision.navigate;
    }
    launchUrl(uri, mode: LaunchMode.externalApplication).then((ok) {
      if (!ok) toast('Could not open ${uri.host}');
    });
    return NavigationDecision.prevent;
  }

  @override
  Widget build(BuildContext context) {
    final skin = settings.skin;
    final body = Column(children: [
      SkinHeader(skin: skin, title: 'Vigil', subtitle: 'homelab watchtower', actions: [
        if (isPhone) IconButton(icon: const Icon(Icons.refresh), onPressed: () => _web?.reload()),
      ]),
      Expanded(
        child: isDesktop
            ? _desktopBody(skin)
            : _web != null
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

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final api = hub.vigilNode?.api;
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

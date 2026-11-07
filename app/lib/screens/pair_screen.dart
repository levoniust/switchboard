import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/platform.dart';
import '../main.dart';
import '../skins/chrome.dart';

/// The name a machine shows for this device in `switchboard devices`.
String deviceName() {
  final host = Platform.localHostname;
  final kind = Platform.isAndroid ? 'phone' : Platform.operatingSystem;
  return host.isEmpty || host == 'localhost' ? 'Switchboard $kind' : '$host ($kind)';
}

/// Add (or re-pair) a machine: accept a `switchboard://pair/…` link, trade its one-time code for a key, save it.
class PairScreen extends StatefulWidget {
  final Server? initial;
  const PairScreen({super.key, this.initial});
  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final _ctrl = TextEditingController();
  String? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) WidgetsBinding.instance.addPostFrameCallback((_) => _pair(widget.initial!));
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData('text/plain');
    if (d?.text != null) _ctrl.text = d!.text!.trim();
  }

  Future<void> _pair(Server s) async {
    setState(() {
      _busy = true;
      _status = 'Testing ${s.hosts.join(' / ')} …';
    });
    final api = Api(s);
    final host = await api.probe();
    if (host == null) {
      setState(() {
        _busy = false;
        _status = 'Could not reach ${s.name}. At home use the Wi-Fi; away, turn Tailscale on. '
            '(It also fails if the certificate does not match the link.)';
      });
      return;
    }
    try {
      // v2 links carry a one-time code: trade it for this device's own key
      final server = s.code != null ? await api.redeem(deviceName()) : s;
      final info = await Api(server).get('/api/info') as Map;
      await hub.add(server.copyWith(id: info['node_id'] as String?, name: info['name'] as String?));
      if (!mounted) return;
      setState(() => _status = 'Paired with ${info['name']} via $host.');
      navKey.currentState?.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const HomeScreen()), (_) => false);
    } catch (e) {
      setState(() {
        _busy = false;
        _status = s.code != null
            ? 'The machine refused the code: $e\nCodes work once and expire after 10 minutes: run `switchboard pair` again.'
            : 'The bridge answered but refused the key: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final skin = settings.skin;
    return Scaffold(
      body: SkinBackground(
        skin: skin,
        child: ListView(padding: EdgeInsets.zero, children: [
          SkinHeader(skin: skin, title: 'Pair', subtitle: isPhone ? 'connect this phone to a computer' : 'connect this device to a machine'),
          SkinPanel(
            skin: skin,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('On the machine you want to add, run', style: TextStyle(color: skin.dim)),
              const SizedBox(height: 6),
              SelectableText('switchboard pair', style: TextStyle(fontFamily: 'JetBrainsMono', color: skin.accent)),
              const SizedBox(height: 10),
              Text('${isPhone ? 'Scan its QR code with the phone camera (or tap the link it prints), or paste' : 'Copy the link it prints and paste'} the link here. '
                  'Each machine you add shows up in the chat list.',
                  style: TextStyle(color: skin.fg)),
              const SizedBox(height: 10),
              TextField(
                controller: _ctrl,
                minLines: 2,
                maxLines: 4,
                style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
                decoration: InputDecoration(
                  hintText: 'switchboard://pair/…',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(icon: const Icon(Icons.content_paste), onPressed: _paste),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () {
                        final s = Server.fromPairLink(_ctrl.text);
                        if (s == null) {
                          setState(() => _status = 'That is not a Switchboard pairing link.');
                        } else {
                          _pair(s);
                        }
                      },
                icon: const Icon(Icons.link),
                label: Text(skin.head('Pair')),
              ),
              if (_status != null) ...[
                const SizedBox(height: 12),
                Text(_status!, style: TextStyle(color: skin.fg)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

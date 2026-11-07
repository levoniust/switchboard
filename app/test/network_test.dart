import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/core/api.dart';
import 'package:switchboard/core/hub.dart';

String link(Map<String, dynamic> j) => 'switchboard://pair/${base64Url.encode(utf8.encode(jsonEncode(j))).replaceAll('=', '')}';

void main() {
  test('v2 pair link: one-time code, node id, no token', () {
    final s = Server.fromPairLink(link({'v': 2, 'id': 'abc', 'n': 'Surface', 'h': ['100.1.2.3'], 'p': 8095, 'c': 'FF', 'k': 'code1'}))!;
    expect(s.code, 'code1');
    expect(s.id, 'abc');
    expect(s.token, '');
    final saved = s.copyWith(token: 'devtok');
    expect(saved.toJson().containsKey('k'), isFalse); // the code is never stored
    expect(Server.fromJson(saved.toJson()).id, 'abc');
    expect(Server.fromPairLink(link({'v': 2, 'n': 'x', 'h': ['h'], 'p': 1, 'c': 'ff'})), isNull); // neither token nor code
  });

  test('same machine: by node id, else by certificate + port', () {
    const a = Server(name: 'a', hosts: ['1'], port: 8095, token: 't', pin: 'p1', id: 'n1');
    expect(a.sameMachine(const Server(name: 'b', hosts: ['2'], port: 9, token: 'u', pin: 'p2', id: 'n1')), isTrue);
    expect(a.sameMachine(const Server(name: 'a', hosts: ['1'], port: 8095, token: 't', pin: 'p1', id: 'n2')), isFalse);
    const old = Server(name: 'a', hosts: ['1'], port: 8095, token: 't', pin: 'p1');
    expect(old.sameMachine(const Server(name: 'z', hosts: ['9'], port: 8095, token: 'x', pin: 'p1')), isTrue);
  });

  test('fleet merges machines; ids only unique per machine', () {
    final f = Fleet();
    final ph = NodeLink()..server = const Server(name: 'Powerhouse', hosts: ['1'], port: 1, token: 't', pin: 'aaaaaaaaaaaaaaaa', id: 'ph');
    final sf = NodeLink()..server = const Server(name: 'Surface', hosts: ['2'], port: 1, token: 't', pin: 'bbbbbbbbbbbbbbbb', id: 'sf');
    f.nodes.addAll([ph, sf]);
    ph.sessions = [Session.fromJson({'id': '@1', 'pane': '%1', 'name': 'claude'}, ph)];
    sf.sessions = [Session.fromJson({'id': '@1', 'pane': '%1', 'name': 'surface-ai'}, sf)];
    ph.alerts = [Alert.fromJson({'id': 1, 'ts': 10, 'type': 'done', 'pane': '%1'}, ph)];
    sf.alerts = [Alert.fromJson({'id': 1, 'ts': 20, 'type': 'question', 'pane': '%1', 'state': 'open'}, sf)];
    expect(f.sessions.map((s) => s.name), ['claude', 'surface-ai']);
    expect(f.sessions.map((s) => s.key).toSet().length, 2);
    expect(f.sessionById('@1', 'sf')!.name, 'surface-ai');
    expect(f.sessionByPane('%1', 'ph')!.name, 'claude');
    expect(f.alerts.first.node, sf); // newest first across machines
    expect(f.sessionFor(f.alerts.first)!.name, 'surface-ai');
    expect(f.openCount, 1);
    expect(f.node(null), ph); // old push links without ?node= go to the first machine
    expect(f.node('nope'), isNull);
  });

  test('Windows paths shorten with backslashes', () {
    expect(Session.fromJson({'id': '1', 'cwd': r'C:\AI\projects\thing'}).shortCwd, r'…\projects\thing');
  });
}

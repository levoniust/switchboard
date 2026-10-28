import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/core/api.dart';
import 'package:switchboard/core/hub.dart';
import 'package:switchboard/skins/skins.dart';

void main() {
  test('pair link round-trips', () {
    final payload = base64Url
        .encode(utf8.encode(jsonEncode({'v': 1, 'n': 'workstation', 'h': ['192.168.1.10', '100.1.2.3'], 'p': 8095, 't': 'tok', 'c': 'AB12'})))
        .replaceAll('=', '');
    final s = Server.fromPairLink('switchboard://pair/$payload')!;
    expect(s.name, 'workstation');
    expect(s.hosts, ['192.168.1.10', '100.1.2.3']);
    expect(s.port, 8095);
    expect(s.pin, 'ab12');
    expect(Server.fromPairLink('switchboard://pair/garbage!!'), isNull);
  });

  test('session + alert parsing', () {
    final s = Session.fromJson({
      'id': '@1', 'index': 1, 'name': 'qwen', 'pane': '%3', 'cwd': '/home/me/projects/switchboard/app', 'kind': 'claude-local',
      'status': 'question', 'pending': {'id': 5, 'type': 'question', 'title': 'Color', 'body': 'Which?', 'state': 'open',
        'options': [{'key': '1', 'label': 'Red'}, {'key': '2', 'label': 'Green'}]},
    });
    expect(s.shortCwd, '…/switchboard/app');
    expect(s.pending!.needsAnswer, isTrue);
    expect(s.pending!.options.map((o) => o.label), ['Red', 'Green']);
  });

  test('every skin builds a theme; Miko skins are private', () {
    for (final s in skins) {
      expect(s.theme, isNotNull);
    }
    expect(skins.where((s) => s.isPrivate).length, 4);
    expect(skinById('nope').id, 'cli');
  });
}

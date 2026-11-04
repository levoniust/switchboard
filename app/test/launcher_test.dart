import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/core/hub.dart';

void main() {
  test('launchers parse from the bridge and fall back for unknown kinds', () {
    final h = Hub();
    expect(h.launchers.map((l) => l.kind), ['claude', 'claude-local', 'shell']);
    h.launchers = [
      Launcher.fromJson({'kind': 'agent-b', 'label': 'Agent B', 'name': 'b', 'claude': true, 'accent': 2, 'icon': 'spark'}),
      Launcher.fromJson({'kind': 'shell', 'claude': false}),
    ];
    expect(h.launcher('agent-b').label, 'Agent B');
    expect(h.launcher('agent-b').accent, 2);
    expect(h.launcher('shell').claude, false);
    final unknown = h.launcher('old-kind');
    expect(unknown.label, 'old-kind');
    expect(unknown.claude, true);
  });

  test('Session.isClaude follows the launcher', () {
    final h = Hub();
    h.launchers = [Launcher.fromJson({'kind': 'tool', 'claude': false})];
    expect(Session.fromJson({'id': '1', 'kind': 'tool'}).isClaude, false);
    expect(Session.fromJson({'id': '2', 'kind': 'shell'}).isClaude, false);
    expect(Session.fromJson({'id': '3', 'kind': 'agent'}).isClaude, true);
  });
}

import 'package:flutter/material.dart';

import '../core/hub.dart';
import '../main.dart';
import '../skins/chrome.dart';
import '../widgets/action_bar.dart';

/// History of alerts (done / permission / question). Open ones can be answered here.
class AlertsScreen extends StatelessWidget {
  final bool standalone;
  const AlertsScreen({super.key, this.standalone = false});

  @override
  Widget build(BuildContext context) {
    final body = ListenableBuilder(
      listenable: Listenable.merge([hub, settings]),
      builder: (context, _) {
        final skin = settings.skin;
        final list = hub.alerts;
        return RefreshIndicator(
          onRefresh: hub.refresh,
          child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            SkinHeader(skin: skin, title: 'Alerts', subtitle: '${hub.openCount} waiting for you'),
            if (list.isEmpty)
              Padding(padding: const EdgeInsets.all(32), child: Text('Nothing yet.', textAlign: TextAlign.center, style: TextStyle(color: skin.dim))),
            for (final a in list)
              SkinPanel(
                skin: skin,
                tint: a.needsAnswer ? statusColor(skin, a.type) : (a.type == 'done' ? skin.ok : skin.dim),
                onTap: () {
                  final s = hub.sessionByPane(a.pane);
                  if (s != null) openTerminal(s);
                },
                child: a.needsAnswer && hub.sessionByPane(a.pane)?.pending?.id == a.id
                    ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        _meta(a, skin),
                        const SizedBox(height: 6),
                        ActionBar(alert: a, skin: skin, compact: true),
                      ])
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        _meta(a, skin),
                        const SizedBox(height: 4),
                        Text(a.title, style: TextStyle(color: skin.fg, fontWeight: FontWeight.w600)),
                        if (a.body.isNotEmpty)
                          Text(a.body, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: skin.fg.withValues(alpha: 0.75), fontSize: 13)),
                        if (a.answered != null)
                          Text('→ ${a.answered}', style: TextStyle(color: skin.accent, fontSize: 12)),
                      ]),
              ),
          ]),
        );
      },
    );
    if (!standalone) return body;
    return Scaffold(body: SkinBackground(skin: settings.skin, child: body));
  }

  Widget _meta(Alert a, skin) {
    final t = a.time;
    final hh = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final day = DateTime.now().difference(t).inHours > 20 ? '${t.month}/${t.day} ' : '';
    final icon = {'done': '✓', 'permission': '⚿', 'question': '?'}[a.type] ?? '•';
    return Text('$icon  ${a.sessionName ?? a.pane ?? ''} · ${a.kind ?? ''} · $day$hh · ${a.state}',
        style: TextStyle(color: skin.dim, fontSize: 11, fontFamily: 'JetBrainsMono'));
  }
}

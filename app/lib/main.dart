import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/api.dart';
import 'core/hub.dart';
import 'core/settings.dart';
import 'screens/alerts_screen.dart';
import 'screens/pair_screen.dart';
import 'screens/sessions_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/terminal_screen.dart';
import 'screens/vigil_screen.dart';
import 'skins/chrome.dart';

final settings = Settings();
final hub = Hub();
final navKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await settings.load();
  final server = await Server.load();
  if (server != null) unawaited(hub.start(server));
  runApp(const SwitchboardApp());
}

void toast(String msg) => messengerKey.currentState
  ?..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));

class SwitchboardApp extends StatefulWidget {
  const SwitchboardApp({super.key});
  @override
  State<SwitchboardApp> createState() => _SwitchboardAppState();
}

class _SwitchboardAppState extends State<SwitchboardApp> {
  final _links = AppLinks();
  StreamSubscription<Uri>? _linkSub;
  late final AppLifecycleListener _life;
  String? _lastLink;

  @override
  void initState() {
    super.initState();
    _linkSub = _links.uriLinkStream.listen(_onLink);
    _life = AppLifecycleListener(onResume: hub.resume, onPause: hub.pause, onHide: hub.pause, onShow: hub.resume);
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _life.dispose();
    super.dispose();
  }

  /// Deep links: `switchboard://pair/PAYLOAD`, `alert/ID`, `answer/ID/KEY`, `session/PANE`, `vigil`.
  Future<void> _onLink(Uri uri) async {
    final s = uri.toString();
    if (s == _lastLink) return; // the initial link can arrive twice
    _lastLink = s;
    final parts = [uri.host, ...uri.pathSegments].where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return;
    switch (parts.first) {
      case 'pair':
        final server = Server.fromPairLink(s);
        if (server == null) return toast('That pairing link is damaged.');
        navKey.currentState?.push(MaterialPageRoute(builder: (_) => PairScreen(initial: server)));
        break;
      case 'alert':
        await _openAlert(int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0);
        break;
      case 'answer':
        if (parts.length < 3) return;
        await _waitOnline();
        try {
          final label = await hub.answer(int.parse(parts[1]), parts[2]);
          toast('Answered: $label');
        } catch (e) {
          toast('Could not answer: $e');
        }
        await _openAlert(int.parse(parts[1]));
        break;
      case 'session':
        await _waitOnline();
        final sess = hub.sessionById(Uri.decodeComponent(parts.length > 1 ? parts[1] : ''));
        if (sess != null) openTerminal(sess);
        break;
      case 'vigil':
        navKey.currentState?.push(MaterialPageRoute(builder: (_) => const VigilScreen(standalone: true)));
        break;
    }
  }

  Future<void> _waitOnline() async {
    for (var i = 0; i < 40 && hub.link != LinkState.online; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> _openAlert(int id) async {
    await _waitOnline();
    try {
      final a = await hub.alert(id);
      final sess = hub.sessionByPane(a.pane);
      if (sess != null) {
        openTerminal(sess);
      } else {
        navKey.currentState?.push(MaterialPageRoute(builder: (_) => const AlertsScreen(standalone: true)));
      }
    } catch (e) {
      toast('Alert not found: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final skin = settings.skin;
        SystemChrome.setSystemUIOverlayStyle(skin.brightness == Brightness.dark
            ? SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent)
            : SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent));
        return MaterialApp(
          title: 'Switchboard',
          debugShowCheckedModeBanner: false,
          navigatorKey: navKey,
          scaffoldMessengerKey: messengerKey,
          theme: skin.theme,
          home: hub.server == null ? const PairScreen() : const HomeScreen(),
        );
      },
    );
  }
}

void openTerminal(Session s) {
  navKey.currentState?.popUntil((r) => r.isFirst);
  navKey.currentState?.push(MaterialPageRoute(builder: (_) => TerminalScreen(sessionId: s.id)));
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int tab = 0;
  StreamSubscription<Alert>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = hub.newAlerts.listen((a) {
      // Foreground: a banner instead of a phone notification (the bridge doesn't push while the app is open).
      if (!mounted || a.type == 'done' && ModalRoute.of(context)?.isCurrent != true) return;
      final who = a.sessionName ?? 'Claude';
      messengerKey.currentState?.showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: a.needsAnswer ? 10 : 4),
        content: Text('$who: ${a.title}${a.body.isNotEmpty ? ' — ${a.body}' : ''}', maxLines: 3, overflow: TextOverflow.ellipsis),
        action: SnackBarAction(label: 'OPEN', onPressed: () {
          final s = hub.sessionByPane(a.pane);
          if (s != null) openTerminal(s);
        }),
      ));
      if (settings.haptics) HapticFeedback.mediumImpact();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final skin = settings.skin;
    final pages = [const SessionsScreen(), const AlertsScreen(), if (true) const VigilScreen(), const SettingsScreen()];
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) => Scaffold(
        body: SkinBackground(skin: skin, child: IndexedStack(index: tab, children: pages)),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            NavigationDestination(icon: const Icon(Icons.terminal), label: skin.head('Chats')),
            NavigationDestination(
              icon: Badge(isLabelVisible: hub.openCount > 0, label: Text('${hub.openCount}'), child: const Icon(Icons.notifications_outlined)),
              label: skin.head('Alerts'),
            ),
            NavigationDestination(icon: const Icon(Icons.radar), label: skin.head('Vigil')),
            NavigationDestination(icon: const Icon(Icons.tune), label: skin.head('Settings')),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:xterm/xterm.dart';

import '../core/ansi.dart';
import '../core/hub.dart';
import '../core/keys.dart';
import '../main.dart';
import '../skins/chrome.dart';
import '../skins/mascot.dart';
import '../skins/skins.dart';
import '../widgets/action_bar.dart';
import '../widgets/extra_keys.dart';
import '../widgets/key_catcher.dart';
import '../widgets/reader_view.dart';

/// Slash commands offered in the palette. `run: true` = send immediately, otherwise put in the input line.
const _commands = <(String, String, bool)>[
  ('/compact', 'Summarise the chat to free up context', true),
  ('/clear', 'Start over with an empty context', true),
  ('/context', 'Show how full the context window is', true),
  ('/cost', 'Tokens and cost of this chat', true),
  ('/status', 'Version, model, account, connectivity', true),
  ('/model', 'Pick the model', true),
  ('/resume', 'Resume an earlier chat', true),
  ('/memory', 'Edit memory files', true),
  ('/permissions', 'Allow / deny tool rules', true),
  ('/agents', 'Manage subagents', true),
  ('/mcp', 'MCP servers', true),
  ('/review', 'Review a pull request', false),
  ('/init', 'Write a CLAUDE.md for this folder', true),
  ('/help', 'All commands', true),
  ('/exit', 'Quit Claude (the window falls back to a shell)', true),
  ('!', 'Run a shell command in the chat (bash mode)', false),
  ('#', 'Add a note to memory', false),
];

/// One chat. Two views of the same tmux window, neither of which ever resizes it:
/// Reader (default) = the chat's text laid out natively by the phone, typed through an input line;
/// Terminal = the raw screen at the PC's size, zoomed to fit, typed into directly.
class TerminalScreen extends StatefulWidget {
  final String sessionId;
  const TerminalScreen({super.key, required this.sessionId});
  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> with WidgetsBindingObserver {
  final terminal = Terminal(maxLines: 5000);
  final termCtrl = TerminalController();
  final composer = TextEditingController();
  final composerFocus = FocusNode();
  final catcherFocus = FocusNode();
  final mods = Modifiers();
  WebSocket? _ws;
  StreamSubscription? _sub;
  Sink<List<int>>? _decoder;
  bool _connecting = false, _closed = false, _showComposer = false;
  late bool _reader = settings.readerDefault;
  Timer? _retry;
  String? _pane;
  DateTime _lastWarn = DateTime(2000);
  String _lastComposer = '';

  // Reader state: the chat's lines as the bridge last sent them, the PC window width, full-screen flag.
  List<String> _lines = [];
  int _width = 80;
  bool _alt = false;
  // Terminal state: the PC window's size and the zoom over "fit to width".
  int _cols = 80, _rows = 30;
  double _zoom = 1;

  Session? get session => hub.sessionById(widget.sessionId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    terminal.onOutput = (data) => _send(data);
    _pane = session?.pane;
    hub.setFocus(_pane);
    composer.addListener(_composerChanged);
    _connect();
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    hub.setFocus(null);
    _retry?.cancel();
    _sub?.cancel();
    _ws?.close();
    _decoder?.close();
    composer.dispose();
    composerFocus.dispose();
    catcherFocus.dispose();
    mods.dispose();
    super.dispose();
  }

  /// Back from the background the old socket is often silently dead: open a fresh one right away.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reconnect();
  }

  void _reconnect() {
    _sub?.cancel();
    _ws?.close();
    _ws = null;
    _retry?.cancel();
    if (mounted) setState(() {});
    _connect();
  }

  Future<void> _connect() async {
    if (_connecting || _closed || hub.api == null) return;
    _connecting = true;
    final reader = _reader;
    try {
      final ws = await hub.api!.socket(
        '/api/sessions/${Uri.encodeComponent(widget.sessionId)}/term',
        query: {'mode': reader ? 'reader' : 'fixed', 'cols': '$_cols', 'rows': '$_rows'},
      );
      if (_closed || reader != _reader) {
        ws.close();
        // the view changed while we were connecting: connect again for the new view (runs after `finally` below)
        if (!_closed) Future.microtask(_connect);
        return;
      }
      _ws = ws;
      if (!reader) {
        _decoder?.close();
        terminal.buffer.clear();
        terminal.buffer.setCursor(0, 0);
        _decoder = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_StringSink(terminal.write));
      }
      _sub = ws.listen(
        (d) {
          if (d is List<int>) {
            _decoder?.add(d);
          } else if (d is String) {
            _control(jsonDecode(d) as Map<String, dynamic>);
          }
        },
        onDone: _lost,
        onError: (_) => _lost(),
        cancelOnError: true,
      );
      if (mounted) setState(() {});
    } catch (e) {
      _lost();
    } finally {
      _connecting = false;
    }
  }

  void _control(Map<String, dynamic> m) {
    if (m['size'] case [final int c, final int r]) {
      _cols = c;
      _rows = r;
      terminal.resize(c, r);
      if (mounted) setState(() {});
    }
    if (m.containsKey('tail')) {
      final drop = (m['drop'] as num).toInt(), keep = (m['keep'] as num).toInt();
      final base = drop < _lines.length ? _lines.sublist(drop) : <String>[];
      _lines = [...base.take(keep), ...(m['tail'] as List).cast<String>()];
      _width = (m['w'] as num?)?.toInt() ?? _width;
      _alt = m['alt'] == true;
      if (mounted) setState(() {});
    }
  }

  void _lost() {
    _ws = null;
    if (_closed) return;
    if (mounted) setState(() {});
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), _connect);
  }

  /// Sends keys to the chat. Offline, say so instead of dropping them silently.
  void _send(String data) {
    final ws = _ws;
    if (ws == null) {
      if (DateTime.now().difference(_lastWarn) > const Duration(seconds: 2)) {
        _lastWarn = DateTime.now();
        toast('Not connected, so that key was not sent. Reconnecting…');
        _reconnect();
      }
      return;
    }
    ws.add(utf8.encode(data));
  }

  /// A key from the extra-keys row (modifiers already applied).
  void _key(String seq) {
    if (seq == '\r' && composer.text.isNotEmpty && (_reader || _showComposer)) return _submit();
    _send(seq);
  }

  /// With CTRL/ALT armed, a letter typed into the input line goes straight to the chat as Ctrl+letter.
  void _composerChanged() {
    final t = composer.text;
    // Some keyboards (Samsung in multi-line boxes) type a newline instead of pressing Send: treat it as Send.
    if (t.length == _lastComposer.length + 1 && t.endsWith('\n') && t.substring(0, t.length - 1) == _lastComposer) {
      composer.value = TextEditingValue(
        text: _lastComposer,
        selection: TextSelection.collapsed(offset: _lastComposer.length),
      );
      _submit();
      return;
    }
    if (mods.any && t.length == _lastComposer.length + 1) {
      final at = composer.selection.baseOffset - 1;
      if (at >= 0 && at < t.length && t.substring(0, at) + t.substring(at + 1) == _lastComposer) {
        final ch = t[at];
        composer.value = TextEditingValue(
          text: _lastComposer,
          selection: TextSelection.collapsed(offset: at),
        );
        _send(mods.apply(ch));
        return;
      }
    }
    _lastComposer = t;
  }

  /// Multi-line text goes in as one bracketed paste so newlines don't submit early; then Enter.
  /// An empty line just sends Enter (confirm a menu choice).
  void _submit({bool enter = true}) {
    final text = composer.text;
    if (text.isEmpty && !enter) return;
    if (text.isNotEmpty) _send(text.contains('\n') ? '\x1b[200~$text\x1b[201~' : text);
    if (enter) {
      if (text.isEmpty) {
        _send('\r');
      } else {
        Future<void>.delayed(const Duration(milliseconds: 60), () => _send('\r'));
      }
    }
    composer.clear();
    _lastComposer = '';
  }

  void _showKeyboard() {
    final f = _showComposer ? composerFocus : catcherFocus;
    f.hasFocus ? SystemChannels.textInput.invokeMethod('TextInput.show') : f.requestFocus();
  }

  void _setView(bool reader) {
    if (reader == _reader) return;
    setState(() => _reader = reader);
    _reconnect();
    if (!reader) WidgetsBinding.instance.addPostFrameCallback((_) => catcherFocus.requestFocus());
  }

  Future<void> _palette() async {
    final skin = settings.skin;
    final pick = await showModalBottomSheet<(String, String, bool)>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(skin.head('Commands'), style: TextStyle(fontSize: 18, color: skin.fg)),
              ),
              for (final c in _commands)
                ListTile(
                  dense: true,
                  title: Text(
                    c.$1,
                    style: TextStyle(fontFamily: 'JetBrainsMono', color: skin.accent),
                  ),
                  subtitle: Text(c.$2),
                  onTap: () => Navigator.pop(context, c),
                ),
            ],
          ),
        ),
      ),
    );
    if (pick == null) return;
    if (pick.$3) {
      _send(pick.$1);
      Future<void>.delayed(const Duration(milliseconds: 80), () => _send('\r'));
    } else {
      setState(() => _showComposer = true);
      composer.text = pick.$1 == '!' || pick.$1 == '#' ? pick.$1 : '${pick.$1} ';
      composer.selection = TextSelection.collapsed(offset: composer.text.length);
      composerFocus.requestFocus();
    }
  }

  Future<void> _attachImage(ImageSource src) async {
    final x = await ImagePicker().pickImage(source: src, imageQuality: 85, maxWidth: 2400);
    if (x == null) return;
    try {
      toast('Uploading…');
      final path = await hub.api!.upload(x.name, await x.readAsBytes());
      setState(() => _showComposer = true);
      composer.text = '${composer.text}${composer.text.isEmpty || composer.text.endsWith(' ') ? '' : ' '}$path ';
      composerFocus.requestFocus();
      toast('Attached $path');
    } catch (e) {
      toast('Upload failed: $e');
    }
  }

  void _bigger(bool up) {
    if (_reader) {
      settings.setReaderFontSize(settings.readerFontSize + (up ? 1 : -1));
    } else {
      setState(() => _zoom = (_zoom * (up ? 1.15 : 1 / 1.15)).clamp(1.0, 4.0));
    }
  }

  void _copy() {
    if (_reader) {
      Clipboard.setData(ClipboardData(text: _lines.map(plain).join('\n')));
      toast('Copied the chat text (long-press to select a part)');
      return;
    }
    final sel = termCtrl.selection;
    Clipboard.setData(ClipboardData(text: sel == null ? terminal.buffer.getText() : terminal.buffer.getText(sel)));
    toast(sel == null ? 'Copied the screen' : 'Copied the selection');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([hub, settings]),
      builder: (context, _) {
        final skin = settings.skin;
        final s = session;
        if (s != null && s.pane != _pane) {
          _pane = s.pane;
          hub.setFocus(_pane);
        }
        final online = _ws != null;
        return Scaffold(
          backgroundColor: skin.term.background,
          resizeToAvoidBottomInset: true,
          appBar: AppBar(
            backgroundColor: skin.style == SkinStyle.material1 ? skin.accent : skin.bg,
            titleSpacing: 0,
            title: Row(
              children: [
                Icon(Icons.circle, size: 10, color: online ? statusColor(skin, s?.status ?? 'idle') : skin.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        skin.head(s?.name ?? 'chat'),
                        style: TextStyle(fontSize: 16, fontFamily: skin.headFont),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        online ? skin.head(statusLabel(s?.status ?? 'idle')) : 'reconnecting…',
                        style: TextStyle(fontSize: 11, color: skin.style == SkinStyle.material1 ? Colors.white70 : skin.dim),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: _reader ? 'Switch to the raw terminal' : 'Switch to Reader',
                icon: Icon(_reader ? Icons.terminal : Icons.article_outlined),
                onPressed: () => _setView(!_reader),
              ),
              IconButton(tooltip: 'Commands', icon: const Icon(Icons.bolt), onPressed: _palette),
              if (!_reader)
                IconButton(
                  tooltip: 'Input line',
                  icon: Icon(_showComposer ? Icons.keyboard_hide : Icons.edit_note),
                  onPressed: () => setState(() {
                    _showComposer = !_showComposer;
                    _showComposer ? composerFocus.requestFocus() : catcherFocus.requestFocus();
                  }),
                ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  switch (v) {
                    case 'photo':
                      _attachImage(ImageSource.gallery);
                    case 'camera':
                      _attachImage(ImageSource.camera);
                    case 'bigger':
                      _bigger(true);
                    case 'smaller':
                      _bigger(false);
                    case 'copy':
                      _copy();
                    case 'reconnect':
                      _reconnect();
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'photo',
                    child: ListTile(leading: Icon(Icons.image_outlined), title: Text('Attach a picture')),
                  ),
                  PopupMenuItem(
                    value: 'camera',
                    child: ListTile(leading: Icon(Icons.photo_camera_outlined), title: Text('Take a photo')),
                  ),
                  PopupMenuItem(
                    value: 'copy',
                    child: ListTile(leading: Icon(Icons.copy), title: Text('Copy')),
                  ),
                  PopupMenuItem(
                    value: 'bigger',
                    child: ListTile(leading: Icon(Icons.text_increase), title: Text('Bigger text')),
                  ),
                  PopupMenuItem(
                    value: 'smaller',
                    child: ListTile(leading: Icon(Icons.text_decrease), title: Text('Smaller text')),
                  ),
                  PopupMenuItem(
                    value: 'reconnect',
                    child: ListTile(leading: Icon(Icons.refresh), title: Text('Reconnect / redraw')),
                  ),
                ],
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            bottom: false, // the extra keys handle the bottom inset; this keeps landscape clear of the nav bar
            child: Column(
              children: [
                if (!online)
                  Material(
                    color: skin.danger,
                    child: InkWell(
                      onTap: _reconnect,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: Row(
                          children: [
                            Icon(Icons.cloud_off, size: 16, color: Colors.white),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Not connected, so keys are not sent. Tap to retry.',
                                style: TextStyle(color: Colors.white, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (s?.pending != null)
                  Container(
                    color: skin.surface,
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (skin.miko != null) MikoBanner(skin: skin, settings: settings, state: s!.pending!.type, session: s.name),
                        ActionBar(alert: s!.pending!, skin: skin),
                      ],
                    ),
                  ),
                if (_reader && _alt && s?.kind == 'shell') // Claude Code itself draws on the alternate screen
                  Material(
                    color: skin.surface,
                    child: ListTile(
                      dense: true,
                      leading: const Icon(Icons.fullscreen),
                      title: Text('A full-screen program is open here', style: TextStyle(color: skin.fg)),
                      trailing: TextButton(onPressed: () => _setView(false), child: const Text('Terminal view')),
                    ),
                  ),
                Expanded(child: _reader ? _readerBody(skin) : _terminalBody(skin)),
                if (_reader || _showComposer) _inputBar(skin),
                if (!_reader) KeyCatcher(focusNode: catcherFocus, mods: mods, onKey: _send),
                ExtraKeys(skin: skin, mods: mods, onKey: _key, online: online),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _readerBody(Skin skin) => ReaderView(
    lines: _lines,
    width: _width,
    join: settings.joinLines,
    skin: skin,
    fontSize: settings.readerFontSize,
    onZoom: settings.setReaderFontSize,
  );

  /// The raw screen at the PC window's size, scaled to fit the phone's width (zoom in to pan sideways).
  Widget _terminalBody(Skin skin) {
    return LayoutBuilder(
      builder: (context, box) {
        const probe = 10.0;
        final tp = TextPainter(
          text: TextSpan(
            text: 'MMMMMMMMMM',
            style: TextStyle(fontFamily: skin.termFont, fontSize: probe, fontFamilyFallback: const ['JetBrainsMono', 'monospace']),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final perChar = tp.width / 10 / probe; // char width per font-size point
        final fit = ((box.maxWidth - 8) / (_cols * perChar)) * 0.99;
        // Fit the PC's width, but never below a readable size (then pan sideways); ⋮ → Bigger zooms further.
        final font = (fit < 7 ? 7.0 : fit) * _zoom;
        final width = font <= fit ? box.maxWidth : _cols * perChar * font + 8;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            height: box.maxHeight,
            child: TerminalView(
              terminal,
              controller: termCtrl,
              theme: skin.term,
              textStyle: TerminalStyle(
                fontSize: font,
                fontFamily: skin.termFont,
                fontFamilyFallback: const ['JetBrainsMono', 'monospace', 'Noto Color Emoji'],
              ),
              padding: const EdgeInsets.all(4),
              cursorType: TerminalCursorType.block,
              autoResize: false, // the phone never resizes the PC's window
              readOnly: true, // typing goes through the KeyCatcher (handles Samsung arrows, Enter, CTRL)
              hardwareKeyboardOnly: true,
              onTapUp: (_, _) => _showKeyboard(),
            ),
          ),
        );
      },
    );
  }

  Widget _inputBar(Skin skin) {
    return Container(
      color: skin.surface,
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: composer,
              focusNode: composerFocus,
              minLines: 1,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              keyboardType: TextInputType.text, // not "multiline", so the keyboard shows Send instead of a newline key
              textInputAction: TextInputAction.send, // keyboard Enter sends (empty line = plain Enter)
              onSubmitted: (_) => _submit(),
              onEditingComplete: () {}, // keep the keyboard up
              style: TextStyle(color: skin.fg, fontSize: 15),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Message · Enter sends · arrows below go to the chat',
                hintStyle: TextStyle(color: skin.dim, fontSize: 13),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          IconButton(tooltip: 'Type without Enter', icon: const Icon(Icons.keyboard_tab), onPressed: () => _submit(enter: false)),
          IconButton.filled(tooltip: 'Send', icon: const Icon(Icons.send), onPressed: _submit),
        ],
      ),
    );
  }
}

class _StringSink implements Sink<String> {
  final void Function(String) onData;
  _StringSink(this.onData);
  @override
  void add(String data) => onData(data);
  @override
  void close() {}
}

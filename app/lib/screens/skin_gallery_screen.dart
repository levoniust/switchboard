import 'package:flutter/material.dart';

import '../core/settings.dart';
import '../main.dart';
import '../skins/chrome.dart';
import '../skins/skins.dart';

/// When each mascot picture shows up, for the gallery captions.
const _when = {
  'idle': 'Idle: chat is waiting for you',
  'working': 'Working: chat is busy',
  'question': 'Question: chat wants you to pick an option',
  'permission': 'Permission: chat wants to run a tool',
  'done': 'Done: chat finished a task',
  'error': 'Error: chat hit a snag or went offline',
  'sleep': 'Sleep: chat has ended',
};

/// Every mascot picture bundled for [skin], with a sample line for each. Tap one to view it full screen.
class SkinGalleryScreen extends StatefulWidget {
  final Skin skin;
  final Settings? source; // defaults to the app's settings; tests pass their own
  const SkinGalleryScreen({super.key, required this.skin, this.source});

  @override
  State<SkinGalleryScreen> createState() => _SkinGalleryScreenState();
}

class _SkinGalleryScreenState extends State<SkinGalleryScreen> {
  late final Settings _s = widget.source ?? settings;
  late final Map<String, String> _pics = _s.mikoPictures(widget.skin.miko!);
  // picked once so the lines don't reshuffle on every rebuild
  late final Map<String, String?> _lines = {for (final st in _pics.keys) st: _s.mikoLine(widget.skin.miko!, st, session: 'your chat')};

  @override
  Widget build(BuildContext context) {
    final skin = widget.skin;
    final entries = _pics.entries.toList();
    return Theme(
      data: skin.theme,
      child: Scaffold(
        body: SkinBackground(
          skin: skin,
          child: Column(children: [
            SkinHeader(
              skin: skin,
              title: skin.name,
              subtitle: '${entries.length} pictures',
              leading: IconButton(icon: Icon(Icons.arrow_back, color: skin.fg), onPressed: () => Navigator.of(context).pop()),
            ),
            Expanded(
              child: entries.isEmpty
                  ? Center(child: Text('No pictures bundled for this skin.', style: TextStyle(color: skin.dim)))
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 220, childAspectRatio: 0.62, mainAxisSpacing: 12, crossAxisSpacing: 12),
                      itemCount: entries.length,
                      itemBuilder: (context, i) => _tile(context, entries, i),
                    ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, List<MapEntry<String, String>> entries, int i) {
    final skin = widget.skin;
    final e = entries[i];
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _PictureViewer(skin: skin, entries: entries, start: i))),
      child: Container(
        decoration: BoxDecoration(
          color: skin.surface,
          borderRadius: BorderRadius.circular(skin.radius.clamp(0, 16)),
          border: Border.all(color: skin.accent.withValues(alpha: 0.35)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AspectRatio(
            aspectRatio: 1,
            child: Hero(
              tag: e.value,
              child: Image.asset(e.value, fit: BoxFit.cover, errorBuilder: (_, _, _) => Icon(Icons.broken_image, color: skin.dim)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: Text(skin.head(e.key), style: TextStyle(color: skin.accent, fontWeight: FontWeight.w700, letterSpacing: 1, fontSize: 13)),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
              child: Text(_lines[e.key] ?? _when[e.key] ?? '',
                  maxLines: 4, overflow: TextOverflow.ellipsis, style: TextStyle(color: skin.fg, fontSize: 12, height: 1.3)),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Full-screen picture: swipe between states, pinch to zoom.
class _PictureViewer extends StatefulWidget {
  final Skin skin;
  final List<MapEntry<String, String>> entries;
  final int start;
  const _PictureViewer({required this.skin, required this.entries, required this.start});

  @override
  State<_PictureViewer> createState() => _PictureViewerState();
}

class _PictureViewerState extends State<_PictureViewer> {
  late final _pages = PageController(initialPage: widget.start);
  late int _at = widget.start;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entries[_at];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        PageView.builder(
          controller: _pages,
          itemCount: widget.entries.length,
          onPageChanged: (i) => setState(() => _at = i),
          itemBuilder: (_, i) => InteractiveViewer(
            maxScale: 5,
            child: Center(child: Hero(tag: widget.entries[i].value, child: Image.asset(widget.entries[i].value, fit: BoxFit.contain))),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.topLeft,
            child: IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.of(context).pop()),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
              child: Text('${_when[e.key] ?? e.key}   ${_at + 1}/${widget.entries.length}',
                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ),
        ),
      ]),
    );
  }
}

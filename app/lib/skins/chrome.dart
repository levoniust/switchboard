import 'dart:math';

import 'package:flutter/material.dart';

import 'skins.dart';

/// Name shown in the CLI skin's prompt (`claude@<server>`); set once the app knows the paired bridge.
String promptHost = 'switchboard';

/// Skin-specific background (starfield, scanlines, neon grid, …) behind a screen.
class SkinBackground extends StatelessWidget {
  final Skin skin;
  final Widget child;
  const SkinBackground({super.key, required this.skin, required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: skin.bg),
      child: CustomPaint(painter: _BgPainter(skin), foregroundPainter: _FgPainter(skin), child: child),
    );
  }
}

class _BgPainter extends CustomPainter {
  final Skin skin;
  _BgPainter(this.skin);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint();
    switch (skin.style) {
      case SkinStyle.galactic:
        final r = Random(7);
        for (var i = 0; i < 160; i++) {
          p.color = Colors.white.withValues(alpha: 0.15 + r.nextDouble() * 0.6);
          canvas.drawCircle(Offset(r.nextDouble() * size.width, r.nextDouble() * size.height), r.nextDouble() * 1.3, p);
        }
        break;
      case SkinStyle.cyberpunk:
        p
          ..color = skin.accent2.withValues(alpha: 0.07)
          ..strokeWidth = 1;
        final horizon = size.height * 0.62;
        for (var y = horizon; y < size.height; y += (y - horizon) * 0.18 + 6) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
        }
        for (var i = -12; i <= 12; i++) {
          canvas.drawLine(Offset(size.width / 2 + i * 14, horizon), Offset(size.width / 2 + i * 90, size.height), p);
        }
        p.shader = LinearGradient(colors: [skin.accent.withValues(alpha: 0.18), Colors.transparent],
                begin: Alignment.bottomCenter, end: Alignment.topCenter)
            .createShader(Rect.fromLTWH(0, horizon - 120, size.width, 120));
        canvas.drawRect(Rect.fromLTWH(0, horizon - 120, size.width, 120), p);
        break;
      case SkinStyle.starship:
        p.color = skin.dim.withValues(alpha: 0.05);
        for (var y = 0.0; y < size.height; y += 28) {
          canvas.drawRect(Rect.fromLTWH(size.width - 6, y, 4, 18), p);
        }
        break;
      case SkinStyle.miko:
        p.color = skin.accent2.withValues(alpha: skin.brightness == Brightness.dark ? 0.05 : 0.08);
        for (var y = 18.0; y < size.height; y += 46) {
          for (var x = ((y ~/ 46).isEven ? 18.0 : 41.0); x < size.width; x += 46) {
            _moon(canvas, Offset(x, y), 4, p);
          }
        }
        break;
      default:
        break;
    }
  }

  void _moon(Canvas c, Offset o, double r, Paint p) {
    final path = Path()
      ..addOval(Rect.fromCircle(center: o, radius: r))
      ..addOval(Rect.fromCircle(center: o.translate(-r * 0.5, -r * 0.2), radius: r * 0.85))
      ..fillType = PathFillType.evenOdd;
    c.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_BgPainter old) => old.skin.id != skin.id;
}

class _FgPainter extends CustomPainter {
  final Skin skin;
  _FgPainter(this.skin);

  @override
  void paint(Canvas canvas, Size size) {
    if (skin.style == SkinStyle.crt || skin.style == SkinStyle.cli) {
      final p = Paint()..color = Colors.black.withValues(alpha: skin.style == SkinStyle.crt ? 0.22 : 0.10);
      for (var y = 0.0; y < size.height; y += 3) {
        canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), p);
      }
      if (skin.style == SkinStyle.crt) {
        final v = Paint()
          ..shader = RadialGradient(colors: [Colors.transparent, Colors.black.withValues(alpha: 0.45)], stops: const [0.65, 1])
              .createShader(Offset.zero & size);
        canvas.drawRect(Offset.zero & size, v);
      }
    }
  }

  @override
  bool shouldRepaint(_FgPainter old) => old.skin.id != skin.id;
}

/// Screen header in the skin's idiom. Material 1 uses a real AppBar instead (see [SkinScaffold]).
class SkinHeader extends StatelessWidget {
  final Skin skin;
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget? leading;
  const SkinHeader({super.key, required this.skin, required this.title, this.subtitle, this.actions = const [], this.leading});

  @override
  Widget build(BuildContext context) {
    final t = skin.head(title);
    final sub = subtitle == null ? null : skin.head(subtitle!);
    Widget body;
    switch (skin.style) {
      case SkinStyle.cli:
        body = Row(children: [
          ?leading,
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: 'claude@$promptHost', style: TextStyle(color: skin.accent)),
              TextSpan(text: ':~\$ ', style: TextStyle(color: skin.dim)),
              TextSpan(text: t.toLowerCase().replaceAll(' ', '-'), style: TextStyle(color: skin.fg)),
              TextSpan(text: ' ▊', style: TextStyle(color: skin.accent)),
              if (sub != null) TextSpan(text: '\n# $sub', style: TextStyle(color: skin.dim, fontSize: 12)),
            ]), style: TextStyle(fontFamily: skin.headFont, fontSize: 16)),
          ),
          ...actions,
        ]);
        break;
      case SkinStyle.starship:
        body = SizedBox(
          height: 64,
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              width: 74,
              decoration: BoxDecoration(color: skin.bands[0], borderRadius: const BorderRadius.only(topLeft: Radius.circular(34))),
              alignment: Alignment.bottomLeft,
              padding: const EdgeInsets.only(left: 10, bottom: 6),
              child: leading ?? Text('${DateTime.now().hour}${DateTime.now().minute}'.padLeft(4, '0'),
                  style: const TextStyle(fontFamily: 'Antonio', color: Colors.black, fontSize: 13)),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: Row(children: [
                    Expanded(
                      child: Text(t, textAlign: TextAlign.right, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontFamily: 'Antonio', fontSize: 26, color: skin.bands[0], letterSpacing: 1.5)),
                    ),
                    ...actions,
                  ]),
                ),
                Row(children: [
                  for (var i = 1; i < skin.bands.length; i++) ...[
                    Expanded(flex: [3, 1, 5, 2][i % 4], child: Container(height: 12, color: skin.bands[i])),
                    const SizedBox(width: 4),
                  ],
                ]),
              ]),
            ),
          ]),
        );
        break;
      case SkinStyle.galactic:
        body = Row(children: [
          ?leading,
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t, style: TextStyle(fontFamily: 'Orbitron', fontWeight: FontWeight.w800, fontSize: 20, color: skin.accent, letterSpacing: 2)),
              Container(margin: const EdgeInsets.only(top: 4), height: 1, width: 160, color: skin.accent2),
              if (sub != null) Text(sub, style: TextStyle(fontSize: 10, color: skin.accent2, letterSpacing: 2)),
            ]),
          ),
          ...actions,
        ]);
        break;
      case SkinStyle.cyberpunk:
        body = Row(children: [
          ?leading,
          Expanded(
            child: Stack(children: [
              Transform.translate(
                  offset: const Offset(2, 1),
                  child: Text(t, style: TextStyle(fontFamily: 'Rajdhani', fontWeight: FontWeight.w700, fontSize: 26, color: skin.accent2.withValues(alpha: 0.8)))),
              Text(t, style: TextStyle(fontFamily: 'Rajdhani', fontWeight: FontWeight.w700, fontSize: 26, color: skin.accent,
                  shadows: [Shadow(color: skin.accent, blurRadius: 12)])),
            ]),
          ),
          ...actions,
        ]);
        break;
      case SkinStyle.crt:
        body = Row(children: [
          ?leading,
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('> $t', style: TextStyle(fontFamily: 'VT323', fontSize: 30, color: skin.fg, shadows: [Shadow(color: skin.fg, blurRadius: 10)])),
              if (sub != null) Text(sub, style: TextStyle(fontFamily: 'VT323', fontSize: 18, color: skin.dim)),
            ]),
          ),
          ...actions,
        ]);
        break;
      case SkinStyle.material1:
        return Material(
          color: skin.accent,
          elevation: 4,
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: 64,
              child: Row(children: [
                const SizedBox(width: 16),
                ?leading,
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t, style: const TextStyle(fontFamily: 'Roboto', fontSize: 20, fontWeight: FontWeight.w500, color: Colors.white)),
                    if (sub != null) Text(sub, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                  ]),
                ),
                ...actions.map((a) => IconTheme(data: const IconThemeData(color: Colors.white), child: a)),
                const SizedBox(width: 4),
              ]),
            ),
          ),
        );
      case SkinStyle.miko:
        body = Row(children: [
          ?leading,
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t, style: TextStyle(fontFamily: skin.headFont, fontSize: 22, fontWeight: FontWeight.w600, color: skin.fg)),
              if (sub != null) Text(sub, style: TextStyle(fontSize: 12, color: skin.dim)),
            ]),
          ),
          ...actions,
        ]);
        break;
    }
    return SafeArea(bottom: false, child: Padding(padding: const EdgeInsets.fromLTRB(12, 8, 8, 8), child: body));
  }
}

/// A content panel (session card, alert card) drawn in the skin's idiom.
class SkinPanel extends StatelessWidget {
  final Skin skin;
  final Widget child;
  final Color? tint; // status colour for the accent edge
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  const SkinPanel({super.key, required this.skin, required this.child, this.tint, this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final c = tint ?? skin.accent;
    final inner = Padding(padding: const EdgeInsets.fromLTRB(14, 12, 12, 12), child: child);
    Widget box;
    switch (skin.style) {
      case SkinStyle.material1:
        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: onTap, onLongPress: onLongPress,
              child: Row(children: [Container(width: 4, height: 72, color: c), Expanded(child: inner)])),
        );
      case SkinStyle.starship:
        box = IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(width: 22, decoration: BoxDecoration(color: c, borderRadius: const BorderRadius.horizontal(left: Radius.circular(22)))),
          const SizedBox(width: 4),
          Expanded(child: DecoratedBox(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c, width: 2))), child: inner)),
        ]));
        break;
      case SkinStyle.cyberpunk:
        box = ClipPath(
          clipper: _CutCorner(14),
          child: DecoratedBox(
            decoration: BoxDecoration(
                color: skin.surface.withValues(alpha: 0.85),
                border: Border(left: BorderSide(color: c, width: 3), top: BorderSide(color: skin.accent2.withValues(alpha: 0.6)))),
            child: inner,
          ),
        );
        break;
      case SkinStyle.galactic:
        box = CustomPaint(painter: _Brackets(c), child: DecoratedBox(
            decoration: BoxDecoration(color: skin.surface.withValues(alpha: 0.6)), child: inner));
        break;
      case SkinStyle.cli:
      case SkinStyle.crt:
        box = DecoratedBox(
            decoration: BoxDecoration(
                border: Border.all(color: c.withValues(alpha: 0.7)), color: skin.surface.withValues(alpha: 0.6)),
            child: inner);
        break;
      case SkinStyle.miko:
        box = DecoratedBox(
          decoration: BoxDecoration(
            color: skin.surface,
            borderRadius: BorderRadius.circular(skin.radius),
            border: Border(left: BorderSide(color: c, width: 4)),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 10, offset: const Offset(0, 3))],
          ),
          child: inner,
        );
        break;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(onTap: onTap, onLongPress: onLongPress, borderRadius: BorderRadius.circular(skin.radius), child: box),
      ),
    );
  }
}

class _CutCorner extends CustomClipper<Path> {
  final double cut;
  _CutCorner(this.cut);
  @override
  Path getClip(Size s) => Path()
    ..moveTo(0, 0)
    ..lineTo(s.width - cut, 0)
    ..lineTo(s.width, cut)
    ..lineTo(s.width, s.height)
    ..lineTo(cut, s.height)
    ..lineTo(0, s.height - cut)
    ..close();
  @override
  bool shouldReclip(_CutCorner old) => false;
}

class _Brackets extends CustomPainter {
  final Color c;
  _Brackets(this.c);
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = c
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const l = 12.0;
    for (final o in [Offset.zero, Offset(s.width, 0), Offset(0, s.height), Offset(s.width, s.height)]) {
      final dx = o.dx == 0 ? l : -l, dy = o.dy == 0 ? l : -l;
      canvas.drawLine(o, o.translate(dx, 0), p);
      canvas.drawLine(o, o.translate(0, dy), p);
    }
  }

  @override
  bool shouldRepaint(_Brackets old) => old.c != c;
}

/// Colour for a session / alert status in this skin.
Color statusColor(Skin skin, String status) {
  switch (status) {
    case 'permission':
    case 'question':
      return skin.style == SkinStyle.material1 ? const Color(0xFFFF9800) : skin.accent2;
    case 'working':
      return skin.accent;
    case 'done':
      return skin.ok;
    case 'error':
      return skin.danger;
    default:
      return skin.dim;
  }
}

String statusLabel(String status) => const {
      'idle': 'idle',
      'working': 'working…',
      'permission': 'needs permission',
      'question': 'has a question',
      'done': 'done',
      'waiting': 'waiting for you',
      'ended': 'ended',
    }[status] ??
    status;

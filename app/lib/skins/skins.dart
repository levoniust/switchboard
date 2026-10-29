import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// Which family of chrome a skin draws (headers, cards, backgrounds differ per style, not just colours).
enum SkinStyle { cli, material1, starship, galactic, cyberpunk, crt, miko }

/// Mascot variant. The pictures and lines live in assets/private/miko/ (not in the public repo):
/// `<pro|hood|chibi|chibinight|chibicozy|latenight>_<idle|working|done|permission|question|error|sleep>.webp` + `lines.json`.
enum MikoSet { pro, hood, chibi, chibiNight, chibiCozy, lateNight }

class Skin {
  final String id, name, blurb;
  final SkinStyle style;
  final Brightness brightness;
  final Color bg, surface, fg, dim, accent, accent2, danger, ok;
  final List<Color> bands; // decorative colour blocks (starship elbows, cyberpunk stripes, …)
  final String uiFont, termFont, headFont;
  final double radius;
  final bool upperCaseHeads;
  final TerminalTheme term;
  final MikoSet? miko;

  const Skin({
    required this.id,
    required this.name,
    required this.blurb,
    required this.style,
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.fg,
    required this.dim,
    required this.accent,
    required this.accent2,
    required this.danger,
    required this.ok,
    required this.bands,
    required this.uiFont,
    required this.termFont,
    required this.headFont,
    required this.radius,
    required this.term,
    this.upperCaseHeads = false,
    this.miko,
  });

  bool get isPrivate => miko != null;

  String head(String s) => upperCaseHeads ? s.toUpperCase() : s;

  ThemeData get theme {
    final m3 = style != SkinStyle.material1;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: brightness == Brightness.dark ? Colors.black : Colors.white,
      secondary: accent2,
      onSecondary: brightness == Brightness.dark ? Colors.black : Colors.white,
      error: danger,
      onError: Colors.white,
      surface: surface,
      onSurface: fg,
    );
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
    return ThemeData(
      useMaterial3: m3,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: bg,
      fontFamily: uiFont,
      canvasColor: surface,
      dividerColor: dim.withValues(alpha: 0.4),
      cardTheme: CardThemeData(
        color: surface,
        elevation: style == SkinStyle.material1 ? 2 : 0,
        shape: shape,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: style == SkinStyle.material1 ? accent : bg,
        foregroundColor: style == SkinStyle.material1 ? Colors.white : fg,
        elevation: style == SkinStyle.material1 ? 4 : 0,
        titleTextStyle: TextStyle(fontFamily: headFont, fontSize: 20, color: style == SkinStyle.material1 ? Colors.white : fg),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: style == SkinStyle.material1 ? accent2 : accent,
        foregroundColor: brightness == Brightness.dark ? Colors.black : Colors.white,
        shape: style == SkinStyle.material1 ? const CircleBorder() : shape,
      ),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: shape, backgroundColor: accent)),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(shape: shape, foregroundColor: fg, side: BorderSide(color: accent))),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: surface, modalBackgroundColor: surface),
      dialogTheme: DialogThemeData(backgroundColor: surface, shape: shape),
      snackBarTheme: SnackBarThemeData(backgroundColor: surface, contentTextStyle: TextStyle(color: fg, fontFamily: uiFont)),
      navigationBarTheme: NavigationBarThemeData(backgroundColor: surface, indicatorColor: accent.withValues(alpha: 0.25)),
    );
  }
}

TerminalTheme _term({
  required Color bg,
  required Color fg,
  required Color cursor,
  Color? selection,
  List<Color>? ansi,
}) {
  final a = ansi ??
      const [
        Color(0xFF1B1F23), Color(0xFFE5534B), Color(0xFF57AB5A), Color(0xFFC69026),
        Color(0xFF539BF5), Color(0xFFB083F0), Color(0xFF39C5CF), Color(0xFFADBAC7),
        Color(0xFF636E7B), Color(0xFFFF938A), Color(0xFF6BC46D), Color(0xFFDAAA3F),
        Color(0xFF6CB6FF), Color(0xFFDCBDFB), Color(0xFF56D4DD), Color(0xFFCDD9E5),
      ];
  return TerminalTheme(
    cursor: cursor,
    selection: selection ?? cursor.withValues(alpha: 0.35),
    foreground: fg,
    background: bg,
    black: a[0], red: a[1], green: a[2], yellow: a[3], blue: a[4], magenta: a[5], cyan: a[6], white: a[7],
    brightBlack: a[8], brightRed: a[9], brightGreen: a[10], brightYellow: a[11],
    brightBlue: a[12], brightMagenta: a[13], brightCyan: a[14], brightWhite: a[15],
    searchHitBackground: const Color(0xFFFFE066),
    searchHitBackgroundCurrent: const Color(0xFFFF9F1C),
    searchHitForeground: Colors.black,
  );
}

const _mono = 'JetBrainsMono';

final skins = <Skin>[
  Skin(
    id: 'cli', name: 'Terminal', blurb: 'Green phosphor on black. The default.',
    style: SkinStyle.cli, brightness: Brightness.dark,
    bg: const Color(0xFF070A08), surface: const Color(0xFF0E1410), fg: const Color(0xFFB8F5C0),
    dim: const Color(0xFF5E8A66), accent: const Color(0xFF7CFF8A), accent2: const Color(0xFF3FD0FF),
    danger: const Color(0xFFFF5F56), ok: const Color(0xFF7CFF8A), bands: const [Color(0xFF7CFF8A)],
    uiFont: _mono, termFont: _mono, headFont: _mono, radius: 2,
    term: _term(bg: const Color(0xFF070A08), fg: const Color(0xFFCFF7D3), cursor: const Color(0xFF7CFF8A)),
  ),
  Skin(
    id: 'material1', name: 'Material 1', blurb: 'Lollipop-era paper, shadows and a round button.',
    style: SkinStyle.material1, brightness: Brightness.light,
    bg: const Color(0xFFEEEEEE), surface: Colors.white, fg: const Color(0xDE000000),
    dim: const Color(0x8A000000), accent: const Color(0xFF3F51B5), accent2: const Color(0xFFFF4081),
    danger: const Color(0xFFF44336), ok: const Color(0xFF4CAF50),
    bands: const [Color(0xFF3F51B5), Color(0xFF303F9F), Color(0xFFFF4081)],
    uiFont: 'Roboto', termFont: _mono, headFont: 'Roboto', radius: 2,
    term: _term(bg: const Color(0xFF263238), fg: const Color(0xFFECEFF1), cursor: const Color(0xFFFF4081)),
  ),
  Skin(
    id: 'starship', name: 'Starship', blurb: 'A 24th-century bridge console: elbows, pills, pastel blocks.',
    style: SkinStyle.starship, brightness: Brightness.dark, upperCaseHeads: true,
    bg: Colors.black, surface: const Color(0xFF0C0C14), fg: const Color(0xFFFFCC99),
    dim: const Color(0xFF9999CC), accent: const Color(0xFFFF9966), accent2: const Color(0xFF9999FF),
    danger: const Color(0xFFCC4444), ok: const Color(0xFF99CC99),
    bands: const [Color(0xFFFF9966), Color(0xFFCC99CC), Color(0xFF9999FF), Color(0xFFFFCC66), Color(0xFFCC6666)],
    uiFont: 'Antonio', termFont: _mono, headFont: 'Antonio', radius: 22,
    term: _term(bg: Colors.black, fg: const Color(0xFFFFCC99), cursor: const Color(0xFFFF9966)),
  ),
  Skin(
    id: 'galactic', name: 'Galactic', blurb: 'Hologram blue and title-crawl yellow, far, far from Earth.',
    style: SkinStyle.galactic, brightness: Brightness.dark, upperCaseHeads: true,
    bg: const Color(0xFF02030A), surface: const Color(0xFF0A1020), fg: const Color(0xFFCFE8FF),
    dim: const Color(0xFF5C7A99), accent: const Color(0xFFFFE81F), accent2: const Color(0xFF4FC3F7),
    danger: const Color(0xFFFF3B30), ok: const Color(0xFF4FC3F7),
    bands: const [Color(0xFFFFE81F), Color(0xFF4FC3F7), Color(0xFFFF3B30)],
    uiFont: 'Orbitron', termFont: _mono, headFont: 'Orbitron', radius: 4,
    term: _term(bg: const Color(0xFF02030A), fg: const Color(0xFFBFE6FF), cursor: const Color(0xFF4FC3F7)),
  ),
  Skin(
    id: 'cyberpunk', name: 'Neon Night', blurb: 'Rain-slick magenta and cyan, chrome and glitch.',
    style: SkinStyle.cyberpunk, brightness: Brightness.dark, upperCaseHeads: true,
    bg: const Color(0xFF0D0221), surface: const Color(0xFF1A0B33), fg: const Color(0xFFE6F7FF),
    dim: const Color(0xFF8A6FB3), accent: const Color(0xFFFF2A6D), accent2: const Color(0xFF05D9E8),
    danger: const Color(0xFFFF2A6D), ok: const Color(0xFF01FFC3),
    bands: const [Color(0xFFFF2A6D), Color(0xFF05D9E8), Color(0xFFF9F002)],
    uiFont: 'Rajdhani', termFont: 'ShareTechMono', headFont: 'Rajdhani', radius: 0,
    term: _term(bg: const Color(0xFF0D0221), fg: const Color(0xFFE6F7FF), cursor: const Color(0xFFFF2A6D), ansi: const [
      Color(0xFF241347), Color(0xFFFF2A6D), Color(0xFF01FFC3), Color(0xFFF9F002), Color(0xFF05D9E8), Color(0xFFD300C5),
      Color(0xFF00F0FF), Color(0xFFD1C5FF), Color(0xFF5A3D8A), Color(0xFFFF6A9A), Color(0xFF5CFFD8), Color(0xFFFFFB7A),
      Color(0xFF6CEBFF), Color(0xFFFF5CF0), Color(0xFF7CF8FF), Color(0xFFFFFFFF),
    ]),
  ),
  Skin(
    id: 'crt', name: 'Amber CRT', blurb: 'A warm 1983 monochrome monitor, scanlines included.',
    style: SkinStyle.crt, brightness: Brightness.dark,
    bg: const Color(0xFF120A00), surface: const Color(0xFF1C1103), fg: const Color(0xFFFFB000),
    dim: const Color(0xFF9A6A00), accent: const Color(0xFFFFB000), accent2: const Color(0xFFFFD27A),
    danger: const Color(0xFFFF6A00), ok: const Color(0xFFFFD27A), bands: const [Color(0xFFFFB000)],
    uiFont: 'VT323', termFont: 'VT323', headFont: 'VT323', radius: 0,
    term: _term(bg: const Color(0xFF120A00), fg: const Color(0xFFFFB000), cursor: const Color(0xFFFFD27A), ansi: const [
      Color(0xFF2A1A00), Color(0xFFFF8A00), Color(0xFFFFC040), Color(0xFFFFD27A), Color(0xFFE0A030), Color(0xFFFFB060),
      Color(0xFFFFC870), Color(0xFFFFB000), Color(0xFF6A4500), Color(0xFFFFA040), Color(0xFFFFD070), Color(0xFFFFE0A0),
      Color(0xFFF0B850), Color(0xFFFFC890), Color(0xFFFFDA9A), Color(0xFFFFE8C0),
    ]),
  ),
  // ---- private build: Miko ----
  Skin(
    id: 'miko', name: 'Miko', blurb: 'Mascot pack: professional. Olive, ivory and gold.',
    style: SkinStyle.miko, brightness: Brightness.light, miko: MikoSet.pro,
    bg: const Color(0xFFF4EFE3), surface: const Color(0xFFFFFBF2), fg: const Color(0xFF2E3238),
    dim: const Color(0xFF7A7568), accent: const Color(0xFF556B2F), accent2: const Color(0xFFB8902A),
    danger: const Color(0xFF9C2F1E), ok: const Color(0xFF556B2F),
    bands: const [Color(0xFF556B2F), Color(0xFFB8902A), Color(0xFF8B2E1F)],
    uiFont: 'Roboto', termFont: _mono, headFont: 'Roboto', radius: 14,
    term: _term(bg: const Color(0xFF23272D), fg: const Color(0xFFF4EFE3), cursor: const Color(0xFFD4AF37)),
  ),
  Skin(
    id: 'miko_hood', name: 'Miko After Hours', blurb: 'Mascot pack: after hours. Hoodie on, green LED glowing.',
    style: SkinStyle.miko, brightness: Brightness.dark, miko: MikoSet.hood,
    bg: const Color(0xFF121416), surface: const Color(0xFF1C1F23), fg: const Color(0xFFE3E5E8),
    dim: const Color(0xFF7E848B), accent: const Color(0xFF39FF6A), accent2: const Color(0xFFB0B5BA),
    danger: const Color(0xFFFF6B5B), ok: const Color(0xFF39FF6A),
    bands: const [Color(0xFF6B7075), Color(0xFF39FF6A), Color(0xFF8B2E1F)],
    uiFont: _mono, termFont: _mono, headFont: _mono, radius: 10,
    term: _term(bg: const Color(0xFF0E1012), fg: const Color(0xFFDDE1E5), cursor: const Color(0xFF39FF6A)),
  ),
  Skin(
    id: 'miko_chibi', name: 'Chibi Miko', blurb: 'Mascot pack: chibi. Tiny, bubbly, sticker-sized.',
    style: SkinStyle.miko, brightness: Brightness.light, miko: MikoSet.chibi,
    bg: const Color(0xFFFFF4EC), surface: Colors.white, fg: const Color(0xFF4A3A3A),
    dim: const Color(0xFFA08C8C), accent: const Color(0xFFE0607E), accent2: const Color(0xFF8DAA5B),
    danger: const Color(0xFFD9534F), ok: const Color(0xFF8DAA5B),
    bands: const [Color(0xFFFFB3C6), Color(0xFFB9D99A), Color(0xFFF7D08A)],
    uiFont: 'Roboto', termFont: _mono, headFont: 'Roboto', radius: 24,
    term: _term(bg: const Color(0xFF2B2230), fg: const Color(0xFFFFF0F5), cursor: const Color(0xFFFF8FB1)),
  ),
  Skin(
    id: 'miko_chibi_night', name: 'Chibi Miko Night', blurb: 'Mascot pack: chibi, dark mode. Sticker Miko on deep plum.',
    style: SkinStyle.miko, brightness: Brightness.dark, miko: MikoSet.chibiNight,
    bg: const Color(0xFF1B1520), surface: const Color(0xFF2A2130), fg: const Color(0xFFF6E8EE),
    dim: const Color(0xFF9C8A98), accent: const Color(0xFFFF8FB1), accent2: const Color(0xFFA9C97A),
    danger: const Color(0xFFFF6B6B), ok: const Color(0xFFA9C97A),
    bands: const [Color(0xFFFF8FB1), Color(0xFFA9C97A), Color(0xFFF7D08A)],
    uiFont: 'Roboto', termFont: _mono, headFont: 'Roboto', radius: 24,
    term: _term(bg: const Color(0xFF150F19), fg: const Color(0xFFFFF0F5), cursor: const Color(0xFFFF8FB1)),
  ),
  Skin(
    id: 'miko_chibi_cozy', name: 'Chibi Miko After Hours', blurb: 'Mascot pack: chibi, after hours. Hoodie, PJs, fuzzy socks.',
    style: SkinStyle.miko, brightness: Brightness.dark, miko: MikoSet.chibiCozy,
    bg: const Color(0xFF141618), surface: const Color(0xFF1F2327), fg: const Color(0xFFE6E8EA),
    dim: const Color(0xFF858B92), accent: const Color(0xFF39FF6A), accent2: const Color(0xFFC9586A),
    danger: const Color(0xFFFF6B5B), ok: const Color(0xFF39FF6A),
    bands: const [Color(0xFF8A9096), Color(0xFF39FF6A), Color(0xFFC9586A)],
    uiFont: 'Roboto', termFont: _mono, headFont: 'Roboto', radius: 24,
    term: _term(bg: const Color(0xFF0E1012), fg: const Color(0xFFDDE1E5), cursor: const Color(0xFF39FF6A)),
  ),
  Skin(
    id: 'miko_latenight', name: 'Miko Late Night', blurb: 'Mascot pack: late night. Wine velvet, candlelight and a wink.',
    style: SkinStyle.miko, brightness: Brightness.dark, miko: MikoSet.lateNight,
    bg: const Color(0xFF170D11), surface: const Color(0xFF24141A), fg: const Color(0xFFF3E4DA),
    dim: const Color(0xFF9A8078), accent: const Color(0xFFE0B25A), accent2: const Color(0xFFB0304A),
    danger: const Color(0xFFFF6B5B), ok: const Color(0xFFE0B25A),
    bands: const [Color(0xFF7A1F33), Color(0xFFE0B25A), Color(0xFFB0304A)],
    uiFont: 'Roboto', termFont: _mono, headFont: 'Roboto', radius: 16,
    term: _term(bg: const Color(0xFF110A0D), fg: const Color(0xFFF3E4DA), cursor: const Color(0xFFE0B25A)),
  ),
];

Skin skinById(String? id) => skins.firstWhere((s) => s.id == id, orElse: () => skins.first);

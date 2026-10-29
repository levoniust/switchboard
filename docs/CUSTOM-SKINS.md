# Skins: viewing the pictures and making your own

## Viewing a mascot skin's pictures

Mascot skins show a picture for each chat state. To see every picture a skin uses:

- **Settings → Skin**, select the mascot skin, then tap **View pictures (N)** under its description.
- Or **long-press** any mascot skin tile to open its pictures without switching to it.

The gallery shows each picture with its state (idle, working, question, permission, done, error, sleep) and a
sample of the mascot's line for it. Tap a picture to open it full screen. Swipe left or right for the next state,
pinch to zoom, and tap ✕ to close.

The button only appears when the build actually contains pictures for that skin. A public build has none, so the
mascot skins and the button stay hidden there.

## Making a custom colour skin

All skins live in `app/lib/skins/skins.dart`, in the `skins` list. Copy an existing entry and change it:

```dart
Skin(
  id: 'ocean', name: 'Ocean', blurb: 'Deep blue with sea-glass green.',
  style: SkinStyle.cli, brightness: Brightness.dark,
  bg: const Color(0xFF071521), surface: const Color(0xFF0D2233), fg: const Color(0xFFD6ECF5),
  dim: const Color(0xFF6E8A99), accent: const Color(0xFF5FE0B7), accent2: const Color(0xFF3FA7D6),
  danger: const Color(0xFFFF6B6B), ok: const Color(0xFF5FE0B7),
  bands: const [Color(0xFF3FA7D6), Color(0xFF5FE0B7), Color(0xFF1C4E6E)],
  uiFont: 'Roboto', termFont: _mono, headFont: 'Roboto', radius: 16,
  term: _term(bg: const Color(0xFF06111B), fg: const Color(0xFFD6ECF5), cursor: const Color(0xFF5FE0B7)),
),
```

| Field | What it does |
|---|---|
| `id` | Saved in preferences. Keep it unique and don't rename it later, or phones that picked it fall back to Terminal. |
| `name`, `blurb` | Tile label and the line under the skin row in Settings. |
| `style` | Header and frame look: `cli`, `material1`, `starship`, `galactic`, `cyberpunk`, `crt` or `miko`. |
| `brightness` | `Brightness.dark` or `.light`, for system bars and Material widgets. |
| `bg`, `surface`, `fg`, `dim` | Background, cards, main text, secondary text. |
| `accent`, `accent2`, `danger`, `ok` | Highlights, second highlight, errors, success. |
| `bands` | Decorative colour blocks (Starship elbows, Cyberpunk stripes, the tile's top strip). |
| `uiFont`, `termFont`, `headFont` | Fonts declared in `pubspec.yaml` (Roboto, JetBrainsMono, Antonio, Orbitron, Rajdhani, ShareTechMono, VT323). |
| `radius` | Corner rounding. |
| `upperCaseHeads` | `true` puts headings in capitals. |
| `term` | Raw terminal colours. `_term()` takes `bg`, `fg` and `cursor`, plus an optional 16-colour `ansi` list. |

Then run `cd app && flutter test` (it checks that every skin builds a theme) and rebuild the APK.

## Making a custom mascot skin

A mascot skin is a colour skin with `style: SkinStyle.miko` and a `miko:` set. Its pictures and lines live in
`app/assets/private/miko/`, which is git-ignored, so your art never ends up in the repo.

1. **Pictures.** Make one `.webp` for each state, named `<prefix>_<state>.webp`:
   `idle`, `working`, `question`, `permission`, `done`, `error`, `sleep`.
   A 384×384 square works well. Chibi/sticker sets look best with a transparent background. Only `<prefix>_idle.webp`
   is strictly required, because any missing state falls back to idle.
2. **Lines** go in `lines.json`, under a voice key, with the same states plus `connected` and `disconnected`.
   `{session}` is replaced with the chat's name:
   ```json
   { "myvoice": { "done": ["{session} is done!", "All finished in {session}."], "idle": ["..."] } }
   ```
   Voices can be shared between skins.
3. **Code.**
   - `app/lib/skins/skins.dart`: add a value to `enum MikoSet` and a `Skin(... style: SkinStyle.miko, miko: MikoSet.yourSet)`.
   - `app/lib/core/settings.dart`: add the set to the prefix map in `_mikoPrefix()` and to the voice map in `mikoLine()`.
   - `app/lib/skins/mascot.dart`: if it's a chibi/sticker set, add it to the `chibi` check (square, unframed picture).
   - `app/test/widget_test.dart`: bump the private skin count.
4. Run `flutter test`, then build. The skin, its tile and its **View pictures** button appear once the pictures are in
   the build.

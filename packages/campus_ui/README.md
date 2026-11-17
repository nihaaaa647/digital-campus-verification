# campus_ui

The shared look of both Digital Campus ID apps, so the student pass and the guard's screen read as one product.

- `CampusTheme.light()` / `dark()`: Material 3 from one brand blue, tinted backgrounds, bold type with a clear order.
- `CampusColors` (a theme extension, `context.campus`): success, danger and warning colours with their text colours, and the live-dot colour. White text on each is above 4.5:1; a test checks it.
- `InitialsAvatar`, `Pill`, `BrandMark`, `PulsingDot`, `initialsOf` (whole letters, so accented and non-Latin names are not cut in half).

The student app follows the phone's light or dark setting. The scanner is always dark, because the camera fills the screen and a bright app around it glares at the guard.

```bash
flutter test
```

To review a screen without a phone, render it in a widget test with the Roboto and MaterialIcons fonts loaded from the Flutter SDK (`bin/cache/artifacts/material_fonts`) and `debugDisableShadows = false`; the default test font and flat shadows hide most visual problems.

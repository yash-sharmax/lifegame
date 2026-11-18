import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// New look (18 Nov 2026, v2.5.0): a fresh, modern palette — midnight
/// indigo background, electric violet as the main accent, mint for
/// "done" and coral for the streak flame. Every colour in the app
/// comes from here — screens must never hard-code a background, card or
/// accent colour of their own. (Constant names are kept from the
/// previous theme so call sites do not change; only the values are new.)
///
/// v2.9.0: dark / light themes. The five surface/text colours
/// ([background], [card], [cardBorder], [ink], [inkSoft]) are
/// theme-aware getters driven by [AppTheme.mode]; the accent colours
/// and gradients are the same in both themes (violet works on light
/// and dark). [onAccent] is the text/icon colour used ON violet
/// gradients and buttons — always white, in both themes. The two
/// ThemeData objects are built by [_theme] from explicit per-brightness
/// values, so building one never depends on the static mode.
abstract final class AppTheme {
  /// The active theme (drives the getters below). Set by
  /// [ThemeController]; defaults to dark.
  static Brightness mode = Brightness.dark;

  // -- palette ------------------------------------------------------------
  // Theme-aware surface / text colours.
  static Color get background => mode == Brightness.light
      ? const Color(0xFFF4F5F7) // soft grey
      : const Color(0xFF0A0E1A); // deep midnight blue
  static Color get card => mode == Brightness.light
      ? const Color(0xFFFFFFFF) // white card
      : const Color(0xFF141A2E); // slate-indigo card
  static Color get cardBorder => mode == Brightness.light
      ? const Color(0xFFE2E5EC) // light edge
      : const Color(0xFF26304D); // card edge
  static Color get ink => mode == Brightness.light
      ? const Color(0xFF17142B) // near-black indigo text
      : const Color(0xFFF2F5FF); // cool-white text
  static Color get inkSoft => mode == Brightness.light
      ? const Color(0xFF5B6478) // muted slate
      : const Color(0xFF9AA3C0); // muted blue-grey

  /// Text / icons sitting ON a violet gradient or button. Always
  /// white — [ink] is dark in the light theme and would be unreadable
  /// on violet. Use this (not [ink]) for gradient-button labels,
  /// filled-button foregrounds, level badges and tile check icons.
  static const Color onAccent = Color(0xFFF2F5FF);

  // Accent colours (the same in both themes).
  static const Color ember = Color(0xFF7C5CFF); // primary: electric violet
  static const Color gold = Color(0xFFFBBF24); // XP gold
  static const Color flame = Color(0xFFFB923C); // streak coral-orange
  static const Color blood = Color(0xFF7C3AED); // deep violet (badges)
  static const Color steel = Color(0xFF64748B); // slate secondary
  static const Color bronze = Color(0xFFF59E0B); // warm amber

  // -- gradients ----------------------------------------------------------
  // All gradients are dark enough for white bold text/icons on top.
  static const LinearGradient heroGradient = LinearGradient(
    colors: [Color(0xFF7C5CFF), Color(0xFF4338CA), Color(0xFF312E81)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const LinearGradient emberGradient = LinearGradient(
    colors: [Color(0xFF7C5CFF), Color(0xFF6D28D9)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const LinearGradient flameGradient = LinearGradient(
    colors: [Color(0xFFFB923C), Color(0xFFF59E0B)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const LinearGradient goldGradient = LinearGradient(
    colors: [Color(0xFFFBBF24), Color(0xFFD97706)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const LinearGradient steelGradient = LinearGradient(
    colors: [Color(0xFF64748B), Color(0xFF334155)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const LinearGradient bloodGradient = LinearGradient(
    colors: [Color(0xFF8B5CF6), Color(0xFF5B21B6)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Mint / teal (v2.9.0): the sixth palette colour. It replaces
  /// [heroGradient] in the picker — hero and ember start with the
  /// same violet, so the picker showed two identical circles (the
  /// double-checkmark bug, 18 Nov 2026).
  static const LinearGradient mintGradient = LinearGradient(
    colors: [Color(0xFF34D399), Color(0xFF059669)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// The colour of a habit's tile, by its stored palette index.
  /// Every entry starts with a different colour — no duplicates.
  static const List<LinearGradient> habitGradients = [
    emberGradient,
    flameGradient,
    goldGradient,
    steelGradient,
    bloodGradient,
    mintGradient,
  ];

  /// The gradient for a habit tile, from its stored [color] value.
  ///
  /// - 0..5: a preset palette index (v2.9.0 stores the index) → that
  ///   preset gradient.
  /// - Any other value: a real colour (an ARGB int — habits stored
  ///   before v2.9.0 kept the gradient's first colour, and v2.9.0
  ///   custom colours store the picked colour) → a gradient built
  ///   from that colour (colour → a darker shade of it), so the tile
  ///   shows the colour the user actually picked.
  static LinearGradient gradientForHabitColor(int color) {
    if (color >= 0 && color < habitGradients.length) {
      return habitGradients[color];
    }
    final base = Color(color);
    final hsl = HSLColor.fromColor(base);
    final darker = hsl
        .withLightness((hsl.lightness * 0.55).clamp(0.0, 1.0))
        .toColor();
    return LinearGradient(
      colors: [base, darker],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
  }

  static ThemeData get dark => _theme(Brightness.dark);

  /// The light theme (v2.9.0): light backgrounds, dark text, the same
  /// violet accent — a proper light palette, not an inverted dark one.
  static ThemeData get light => _theme(Brightness.light);

  static ThemeData _theme(Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final bg = isLight
        ? const Color(0xFFF4F5F7)
        : const Color(0xFF0A0E1A);
    final cardColor = isLight
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF141A2E);
    final border = isLight
        ? const Color(0xFFE2E5EC)
        : const Color(0xFF26304D);
    final text = isLight
        ? const Color(0xFF17142B)
        : const Color(0xFFF2F5FF);
    final muted = isLight
        ? const Color(0xFF5B6478)
        : const Color(0xFF9AA3C0);
    final scheme = isLight
        ? const ColorScheme.light(
            primary: ember,
            secondary: flame,
            surface: Color(0xFFFFFFFF),
            onSurface: Color(0xFF17142B),
            error: flame,
          )
        : const ColorScheme.dark(
            primary: ember,
            secondary: flame,
            surface: Color(0xFF141A2E),
            onSurface: Color(0xFFF2F5FF),
            error: flame,
          );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      textTheme: TextTheme(
        displaySmall: TextStyle(
          color: text,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
        headlineMedium: TextStyle(
          color: text,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
        bodyMedium: TextStyle(color: text),
        bodyLarge: TextStyle(color: text),
        bodySmall: TextStyle(color: muted),
        titleMedium: TextStyle(color: text, fontWeight: FontWeight.w700),
        titleLarge: TextStyle(color: text, fontWeight: FontWeight.w800),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          color: text,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: border),
        ),
      ),
      listTileTheme: ListTileThemeData(iconColor: text),
      iconTheme: IconThemeData(color: text),
      dividerColor: border,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ember,
          foregroundColor: onAccent,
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: BorderSide(color: border, width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: ember),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: ember,
        foregroundColor: onAccent,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: cardColor,
        indicatorColor: ember.withValues(alpha: 0.22),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? ember : muted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected) ? ember : muted,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w800
                : FontWeight.w600,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: cardColor,
        selectedIconTheme: const IconThemeData(color: ember),
        unselectedIconTheme: IconThemeData(color: muted),
        selectedLabelTextStyle: const TextStyle(
          color: ember,
          fontWeight: FontWeight.w800,
        ),
        unselectedLabelTextStyle: TextStyle(color: muted),
        indicatorColor: ember.withValues(alpha: 0.28),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? onAccent
              : muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? ember : border,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? ember
              : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(onAccent),
        side: BorderSide(color: muted, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: ember,
        linearTrackColor: border,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: cardColor,
        contentTextStyle: TextStyle(color: text),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: border),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(24)),
          side: BorderSide(color: border),
        ),
        titleTextStyle: TextStyle(
          color: text,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
        contentTextStyle: TextStyle(color: text),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bg,
        hintStyle: TextStyle(color: muted),
        labelStyle: TextStyle(color: muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: ember, width: 2),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          side: BorderSide(color: border),
        ),
      ),
    );
  }
}

/// The dark / light theme switch (v2.9.0). Persists the choice
/// locally (SharedPreferences) so it survives restarts; the default
/// is dark. [LifeGameApp] listens to this and rebuilds the MaterialApp
/// with [AppTheme.dark] or [AppTheme.light].
class ThemeController extends ChangeNotifier {
  ThemeController._();

  static final ThemeController instance = ThemeController._();

  static const _key = 'lifegame_theme_mode_v1';

  Brightness _mode = Brightness.dark;

  Brightness get mode => _mode;

  bool get isLight => _mode == Brightness.light;

  /// Loads the saved choice (defaults to dark) and applies it.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key);
      _mode = saved == 'light' ? Brightness.light : Brightness.dark;
    } catch (_) {
      _mode = Brightness.dark;
    }
    AppTheme.mode = _mode;
    notifyListeners();
  }

  /// Sets the theme and persists it.
  Future<void> setMode(Brightness mode) async {
    if (_mode == mode) return;
    _mode = mode;
    AppTheme.mode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        mode == Brightness.light ? 'light' : 'dark',
      );
    } catch (_) {}
  }

  Future<void> toggle() =>
      setMode(isLight ? Brightness.dark : Brightness.light);
}

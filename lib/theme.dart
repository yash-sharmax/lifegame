import 'package:flutter/material.dart';

/// New look (18 Nov 2026, v2.5.0): a fresh, modern palette — midnight
/// indigo background, electric violet as the main accent, mint for
/// "done" and coral for the streak flame. Every colour in the app
/// comes from here — screens must never hard-code a background, card or
/// accent colour of their own. (Constant names are kept from the
/// previous theme so call sites do not change; only the values are new.)
abstract final class AppTheme {
  // -- palette ------------------------------------------------------------
  static const Color background = Color(0xFF0A0E1A); // deep midnight blue
  static const Color card = Color(0xFF141A2E); // slate-indigo card
  static const Color cardBorder = Color(0xFF26304D); // card edge
  static const Color ink = Color(0xFFF2F5FF); // cool-white text
  static const Color inkSoft = Color(0xFF9AA3C0); // muted blue-grey
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

  /// The colour of a habit's tile, by its stored palette index.
  static const List<LinearGradient> habitGradients = [
    emberGradient,
    flameGradient,
    goldGradient,
    steelGradient,
    bloodGradient,
    heroGradient,
  ];

  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: ember,
      secondary: flame,
      surface: card,
      onSurface: ink,
      error: flame,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      textTheme: const TextTheme(
        displaySmall: TextStyle(
          color: ink,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
        headlineMedium: TextStyle(
          color: ink,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
        bodyMedium: TextStyle(color: ink),
        bodyLarge: TextStyle(color: ink),
        bodySmall: TextStyle(color: inkSoft),
        titleMedium: TextStyle(color: ink, fontWeight: FontWeight.w700),
        titleLarge: TextStyle(color: ink, fontWeight: FontWeight.w800),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          color: ink,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
      cardTheme: const CardThemeData(
        color: card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
          side: BorderSide(color: cardBorder),
        ),
      ),
      listTileTheme: const ListTileThemeData(iconColor: ink),
      iconTheme: const IconThemeData(color: ink),
      dividerColor: cardBorder,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ember,
          foregroundColor: AppTheme.ink,
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          side: const BorderSide(color: cardBorder, width: 1.5),
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
        foregroundColor: AppTheme.ink,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: card,
        indicatorColor: ember.withValues(alpha: 0.22),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? ember : inkSoft,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected) ? ember : inkSoft,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w800
                : FontWeight.w600,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: card,
        selectedIconTheme: const IconThemeData(color: ember),
        unselectedIconTheme: const IconThemeData(color: inkSoft),
        selectedLabelTextStyle: const TextStyle(
          color: ember,
          fontWeight: FontWeight.w800,
        ),
        unselectedLabelTextStyle: const TextStyle(color: inkSoft),
        indicatorColor: ember.withValues(alpha: 0.22),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppTheme.ink
              : inkSoft,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? ember
              : cardBorder,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? ember
              : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(AppTheme.ink),
        side: const BorderSide(color: inkSoft, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: ember,
        linearTrackColor: cardBorder,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: card,
        contentTextStyle: const TextStyle(color: ink),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: cardBorder),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
          side: BorderSide(color: cardBorder),
        ),
        titleTextStyle: TextStyle(
          color: ink,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
        contentTextStyle: TextStyle(color: ink),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: background,
        hintStyle: const TextStyle(color: inkSoft),
        labelStyle: const TextStyle(color: inkSoft),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: cardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: ember, width: 2),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          side: BorderSide(color: cardBorder),
        ),
      ),
    );
  }
}

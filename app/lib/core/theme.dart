import 'package:flutter/material.dart';

/// IPChakra brand theme v2 - dark, premium, electric, with glass surfaces.
class ChakraTheme {
  static const Color bg = Color(0xFF05070F);
  static const Color card = Color(0xFF101731);
  static const Color cardBorder = Color(0xFF1E2A4D);
  static const Color violet = Color(0xFF7C3AED);
  static const Color cyan = Color(0xFF06B6D4);
  static const Color textMain = Color(0xFFE9EDF9);
  static const Color textDim = Color(0xFF8B93B0);
  static const Color green = Color(0xFF22C55E);
  static const Color amber = Color(0xFFF59E0B);
  static const Color red = Color(0xFFEF4444);

  /// Emerald used by the connected state.
  static const Color emerald = Color(0xFF10B981);

  // Glass surfaces: translucent white fills that sit over the animated
  // background and let a hint of colour bleed through.
  static const Color glassFill = Color(0x0FFFFFFF); // white at ~6% alpha
  static const Color glassBorder = Color(0x1AFFFFFF); // white at ~10% alpha

  // Corner radii used across the v2 UI.
  static const double radiusLg = 22;
  static const double radiusMd = 16;

  static const LinearGradient brandGradient = LinearGradient(
    colors: [violet, cyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient connectedGradient = LinearGradient(
    colors: [emerald, cyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient dangerGradient = LinearGradient(
    colors: [Color(0xFFEF4444), Color(0xFFF59E0B)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Soft outer glows matching the brand colours.
  static const List<BoxShadow> glowViolet = [
    BoxShadow(
      color: Color(0x667C3AED),
      blurRadius: 32,
      spreadRadius: 2,
      offset: Offset(0, 8),
    ),
  ];

  static const List<BoxShadow> glowCyan = [
    BoxShadow(
      color: Color(0x5906B6D4),
      blurRadius: 32,
      spreadRadius: 2,
      offset: Offset(0, 8),
    ),
  ];

  static const List<BoxShadow> glowGreen = [
    BoxShadow(
      color: Color(0x6610B981),
      blurRadius: 36,
      spreadRadius: 3,
      offset: Offset(0, 8),
    ),
  ];

  static ThemeData dark() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: violet,
        secondary: cyan,
        surface: card,
        error: red,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: textMain,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: const CardThemeData(
        color: card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(21)),
          side: BorderSide(color: cardBorder),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: bg,
        selectedItemColor: cyan,
        unselectedItemColor: textDim,
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: cyan,
        unselectedLabelColor: textDim,
        indicatorColor: cyan,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: card,
        contentTextStyle: TextStyle(color: textMain),
      ),
    );
  }
}

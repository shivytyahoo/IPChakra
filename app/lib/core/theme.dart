import 'package:flutter/material.dart';

/// IPChakra brand theme - dark, premium, electric.
class ChakraTheme {
  static const Color bg = Color(0xFF070B16);
  static const Color card = Color(0xFF101731);
  static const Color cardBorder = Color(0xFF1E2A4D);
  static const Color violet = Color(0xFF7C3AED);
  static const Color cyan = Color(0xFF06B6D4);
  static const Color textMain = Color(0xFFE9EDF9);
  static const Color textDim = Color(0xFF8B93B0);
  static const Color green = Color(0xFF22C55E);
  static const Color amber = Color(0xFFF59E0B);
  static const Color red = Color(0xFFEF4444);

  static const LinearGradient brandGradient = LinearGradient(
    colors: [violet, cyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient dangerGradient = LinearGradient(
    colors: [Color(0xFFEF4444), Color(0xFFF59E0B)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

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
            color: textMain, fontSize: 20, fontWeight: FontWeight.w700),
      ),
      cardTheme: CardThemeData(
        color: card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
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

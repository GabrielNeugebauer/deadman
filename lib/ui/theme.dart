import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class DmColors {
  static const bg = Color(0xFF0A0B0D);
  static const surface = Color(0xFF14161A);
  static const raised = Color(0xFF1B1E23);
  static const line = Color(0xFF262A31);
  static const text = Color(0xFFF2F3F5);
  static const muted = Color(0xFF8A8F98);
  static const alive = Color(0xFF3DF5A7);
  static const warn = Color(0xFFFFB547);
  static const danger = Color(0xFFFF4D5E);
  static const plus = Color(0xFF9B7BFF);
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: DmColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: DmColors.alive,
      onPrimary: DmColors.bg,
      secondary: DmColors.plus,
      surface: DmColors.surface,
      onSurface: DmColors.text,
      error: DmColors.danger,
    ),
  );
  final body = GoogleFonts.interTextTheme(base.textTheme).apply(
    bodyColor: DmColors.text,
    displayColor: DmColors.text,
  );
  return base.copyWith(
    textTheme: body.copyWith(
      displayLarge: GoogleFonts.spaceGrotesk(
          fontSize: 44, fontWeight: FontWeight.w700, color: DmColors.text),
      headlineMedium: GoogleFonts.spaceGrotesk(
          fontSize: 28, fontWeight: FontWeight.w700, color: DmColors.text),
      titleLarge: GoogleFonts.spaceGrotesk(
          fontSize: 20, fontWeight: FontWeight.w600, color: DmColors.text),
    ),
    cardTheme: const CardThemeData(
      color: DmColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
        side: BorderSide(color: DmColors.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        foregroundColor: DmColors.text,
        side: const BorderSide(color: DmColors.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: DmColors.raised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: DmColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: DmColors.line),
      ),
      labelStyle: const TextStyle(color: DmColors.muted),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: DmColors.surface,
      indicatorColor: Color(0x333DF5A7),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

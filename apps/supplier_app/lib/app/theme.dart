import 'package:flutter/material.dart';

/// Colour tokens from .impeccable.md ("precision console").
abstract final class Tokens {
  static const canvas = Color(0xFFF3F5F8);
  static const surface = Color(0xFFFFFFFF);
  static const sunken = Color(0xFFEDF0F4);
  static const groupRow = Color(0xFFF6F8FB);
  static const rule = Color(0xFFDCE1E8);
  static const ruleStrong = Color(0xFFC3CAD6);
  static const ink = Color(0xFF111827);
  static const ink2 = Color(0xFF4B5565);
  static const ink3 = Color(0xFF636C7E);
  static const accent = Color(0xFF285FF0);
  static const accentDeep = Color(0xFF1B47C2);
  static const accentTint = Color(0xFFE8EFFF);
  static const nav = Color(0xFF0E1729);
  static const navHover = Color(0xFF1A2640);
  static const navInk = Color(0xFFC7D0E0);
  static const navInk3 = Color(0xFF7C89A3);
  static const amber = Color(0xFF9A5000);
  static const amberBg = Color(0xFFFFF2DF);
  static const red = Color(0xFFB8302A);
  static const redBg = Color(0xFFFDE8E6);
  static const radius = 8.0;
}

/// Latin/numerals first, then the platform's own CJK face.
const fontFallback = [
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'PingFang SC',
  'Noto Sans SC',
  'Noto Sans CJK SC',
];

const tabular = [FontFeature.tabularFigures()];

ThemeData buildTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: Tokens.accent,
    onPrimary: Colors.white,
    primaryContainer: Tokens.accentTint,
    onPrimaryContainer: Tokens.accentDeep,
    secondary: Tokens.ink2,
    onSecondary: Colors.white,
    error: Tokens.red,
    onError: Colors.white,
    errorContainer: Tokens.redBg,
    onErrorContainer: Tokens.red,
    surface: Tokens.surface,
    onSurface: Tokens.ink,
    onSurfaceVariant: Tokens.ink2,
    outline: Tokens.ruleStrong,
    outlineVariant: Tokens.rule,
    surfaceContainerLowest: Tokens.surface,
    surfaceContainerLow: Tokens.canvas,
    surfaceContainer: Tokens.canvas,
    surfaceContainerHigh: Tokens.sunken,
    surfaceContainerHighest: Tokens.sunken,
  );
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Tokens.radius),
  );
  const text = TextTheme(
    titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    bodyLarge: TextStyle(fontSize: 14),
    bodyMedium: TextStyle(fontSize: 13),
    bodySmall: TextStyle(fontSize: 12, color: Tokens.ink3),
    labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    labelMedium: TextStyle(fontSize: 12, color: Tokens.ink3),
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Tokens.canvas,
    fontFamilyFallback: fontFallback,
    textTheme: text,
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
  );
  final side = const BorderSide(color: Tokens.ruleStrong);
  return base.copyWith(
    dividerTheme: const DividerThemeData(
      color: Tokens.rule,
      space: 1,
      thickness: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: shape,
        side: side,
        foregroundColor: Tokens.ink,
        backgroundColor: Tokens.surface,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: shape),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Tokens.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.radius),
        borderSide: side,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.radius),
        borderSide: side,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.radius),
        borderSide: const BorderSide(color: Tokens.accent, width: 2),
      ),
      labelStyle: const TextStyle(color: Tokens.ink2),
      hintStyle: const TextStyle(color: Tokens.ink3),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Tokens.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 0,
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Tokens.ink,
    ),
    cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
  );
}

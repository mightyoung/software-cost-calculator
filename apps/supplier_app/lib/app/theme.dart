import 'dart:io';

import 'package:flutter/material.dart';

/// Colour tokens from .impeccable.md ("precision console"), light and dark.
/// [dark] is set once per build of the app root (see app.dart), which
/// rebuilds everything when it changes.
abstract final class Tokens {
  static var dark = false;
  static Color _pick(int light, int night) => Color(dark ? night : light);

  static Color get canvas => _pick(0xFFF3F5F8, 0xFF0F1420);
  static Color get surface => _pick(0xFFFFFFFF, 0xFF161C29);
  static Color get sunken => _pick(0xFFEDF0F4, 0xFF1C2333);
  static Color get groupRow => _pick(0xFFF6F8FB, 0xFF1A2130);
  static Color get rule => _pick(0xFFDCE1E8, 0xFF2A3345);
  static Color get ruleStrong => _pick(0xFFC3CAD6, 0xFF3A4459);
  static Color get ink => _pick(0xFF111827, 0xFFE6EAF2);
  static Color get ink2 => _pick(0xFF4B5565, 0xFFB3BCCD);
  static Color get ink3 => _pick(0xFF636C7E, 0xFF8C96AA);
  static Color get accent => _pick(0xFF285FF0, 0xFF5B8CFF);
  static Color get accentDeep => _pick(0xFF1B47C2, 0xFF93B2FF);
  static Color get accentTint => _pick(0xFFE8EFFF, 0xFF1C2A4D);
  static Color get nav => _pick(0xFF0E1729, 0xFF0A0F1A);
  static Color get navHover => _pick(0xFF1A2640, 0xFF18223A);
  static Color get navInk => _pick(0xFFC7D0E0, 0xFFC7D0E0);
  static Color get navInk3 => _pick(0xFF7C89A3, 0xFF7C89A3);
  static Color get amber => _pick(0xFF9A5000, 0xFFF0A649);
  static Color get amberBg => _pick(0xFFFFF2DF, 0xFF3A2A12);
  static Color get red => _pick(0xFFB8302A, 0xFFFF7A70);
  static Color get redBg => _pick(0xFFFDE8E6, 0xFF3D1B1B);

  /// Good outcomes only: lowest valid price, awarded. Blue stays for what
  /// can be clicked or is selected.
  static Color get green => _pick(0xFF17693F, 0xFF4CC38A);
  static Color get greenBg => _pick(0xFFE6F4EC, 0xFF14301F);
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

/// Model numbers and codes: each platform's own monospace face.
const monoFamily = 'Consolas';
const monoFallback = [
  'Menlo',
  'SF Mono',
  'Cascadia Mono',
  'monospace',
  ...fontFallback,
];

const tabular = [FontFeature.tabularFigures()];

ThemeData buildTheme() {
  final scheme = ColorScheme(
    brightness: Tokens.dark ? Brightness.dark : Brightness.light,
    primary: Tokens.accent,
    // Light blue in the dark theme carries dark text (white would fail
    // contrast); selected chips turn blue-tinted instead of light grey.
    onPrimary: Tokens.dark ? const Color(0xFF0B1221) : Colors.white,
    secondaryContainer: Tokens.dark ? Tokens.accentTint : Tokens.ink2,
    onSecondaryContainer: Tokens.dark ? Tokens.accentDeep : Colors.white,
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
    inverseSurface: Tokens.ink,
    onInverseSurface: Tokens.surface,
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
  final text = TextTheme(
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
    // Windows 11's Segoe UI Variable reads better than Segoe UI at small
    // sizes; Windows 10 falls back to Segoe UI. Other platforms keep their
    // system face.
    fontFamily: Platform.isWindows ? 'Segoe UI Variable Text' : null,
    fontFamilyFallback: [if (Platform.isWindows) 'Segoe UI', ...fontFallback],
    textTheme: text,
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
  );
  final side = BorderSide(color: Tokens.ruleStrong);
  return base.copyWith(
    dividerTheme: DividerThemeData(color: Tokens.rule, space: 1, thickness: 1),
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
        borderSide: BorderSide(color: Tokens.accent, width: 2),
      ),
      labelStyle: TextStyle(color: Tokens.ink2),
      hintStyle: TextStyle(color: Tokens.ink3),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Tokens.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 0,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Tokens.ink,
      contentTextStyle: TextStyle(color: Tokens.surface, fontSize: 13),
      actionTextColor: Tokens.accentTint,
    ),
    cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
  );
}

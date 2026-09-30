import 'dart:io';

import 'package:flutter/material.dart';
import 'motion.dart';

/// Shared workspace colours, light and dark; see DESIGN.md.
/// [dark] is set once per build of the app root (see app.dart), which
/// rebuilds everything when it changes.
abstract final class Tokens {
  static var dark = false;
  static Color _pick(int light, int night) => Color(dark ? night : light);

  static Color get canvas => _pick(0xFFF7F8FA, 0xFF131211);
  static Color get surface => _pick(0xFFFFFFFF, 0xFF181716);
  static Color get sunken => _pick(0xFFF1F3F6, 0xFF242321);
  static Color get groupRow => _pick(0xFFF6F8FB, 0xFF201F1D);
  static Color get rule => _pick(0xFFE2E6EC, 0xFF35332F);
  static Color get ruleStrong => _pick(0xFFC3CAD6, 0xFF45423E);
  static Color get ink => _pick(0xFF111827, 0xFFEEEDEA);
  static Color get ink2 => _pick(0xFF4B5565, 0xFFC2BFBA);
  static Color get ink3 => _pick(0xFF636C7E, 0xFFAAA7A3);
  static Color get accent => _pick(0xFF2458D3, 0xFF7BA2FF);
  static Color get accentDeep => _pick(0xFF1B47C2, 0xFF93B2FF);
  static Color get accentTint => _pick(0xFFE8EFFF, 0xFF1C2A4D);
  static Color get nav => _pick(0xFFEEF1F5, 0xFF151413);
  static Color get navHover => _pick(0xFFE2E8F2, 0xFF302E2B);
  static Color get navInk => _pick(0xFF374357, 0xFFD1CECA);
  static Color get navInk3 => _pick(0xFF5B677B, 0xFFAAA7A3);
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

/// System UI faces keep Chinese and Latin text in the same visual rhythm.
const fontFallback = [
  'Noto Sans SC',
  'PingFang SC',
  'Microsoft YaHei UI',
  'Microsoft YaHei',
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
    secondaryContainer: Tokens.accentTint,
    onSecondaryContainer: Tokens.accentDeep,
    primaryContainer: Tokens.accentTint,
    onPrimaryContainer: Tokens.accentDeep,
    secondary: Tokens.ink2,
    onSecondary: Tokens.dark ? Tokens.canvas : Colors.white,
    error: Tokens.red,
    onError: Tokens.dark ? Tokens.canvas : Colors.white,
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
    titleLarge: TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w600,
      height: 1.35,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      height: 1.4,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.4,
    ),
    bodyLarge: TextStyle(fontSize: 14, height: 1.5),
    bodyMedium: TextStyle(fontSize: 13, height: 1.5),
    bodySmall: TextStyle(fontSize: 12, height: 1.5, color: Tokens.ink3),
    labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    labelMedium: TextStyle(fontSize: 12, color: Tokens.ink3),
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Tokens.canvas,
    // One bundled variable family covers Chinese, Latin and numerals without
    // network font loading or platform-dependent CJK substitutions.
    fontFamily: 'Noto Sans SC',
    fontFamilyFallback: [if (Platform.isWindows) 'Segoe UI', ...fontFallback],
    textTheme: text,
    visualDensity: Platform.isAndroid || Platform.isIOS
        ? VisualDensity.standard
        : VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
  );
  final side = BorderSide(color: Tokens.ruleStrong);
  return base.copyWith(
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: const AccessiblePageTransitions(),
      },
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Tokens.surface,
      indicatorColor: Tokens.accentTint,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? Tokens.accentDeep
              : Tokens.ink2,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
          color: states.contains(WidgetState.selected)
              ? Tokens.accentDeep
              : Tokens.ink2,
        ),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Tokens.canvas,
      foregroundColor: Tokens.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
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
      actionTextColor: Tokens.dark
          ? const Color(0xFF1B47C2)
          : Tokens.accentTint,
    ),
    cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
  );
}

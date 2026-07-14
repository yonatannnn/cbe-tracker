import 'package:flutter/material.dart';

/// App-wide theme (§8 Phase 0).
///
/// Light, Material 3, green seed (finance app). Also exposes the reusable
/// text styles the transaction UI leans on: a large "money" style and a
/// monospace style for FT reference numbers.
class AppTheme {
  AppTheme._();

  /// Green seed for the ColorScheme.
  static const Color seedColor = Color(0xFF1B7A43);

  static ThemeData light() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.light,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
    );
  }
}

/// Reusable text styles referenced across transaction screens.
///
/// Pull the exact size/weight from here rather than re-deriving per screen so
/// amounts and references look identical everywhere.
class AppTextStyles {
  AppTextStyles._();

  /// Large amount display (read-only confirm card, balance cards). 23px / w500.
  static const TextStyle money = TextStyle(
    fontSize: 23,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
  );

  /// Monospace style for FT reference numbers so digits align and read cleanly.
  static const TextStyle mono = TextStyle(
    fontFamily: 'monospace',
    fontFeatures: [FontFeature.tabularFigures()],
    letterSpacing: 0.5,
  );
}

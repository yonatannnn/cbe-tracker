import 'package:flutter/material.dart';

/// Design tokens (§8 Phase 0, reworked in Phase 9).
///
/// The organising idea: this app is a reconciliation instrument, not a wealth
/// dashboard. The owner's question at the end of the day is "did anything slip
/// through?", so colour is spent on ANSWERING that, never on decoration.
///
/// Concretely: surfaces are neutral. The first cut seeded the whole
/// ColorScheme from green, which tinted every background, card and sheet pale
/// mint — and when everything is green, "green = money in" and "green =
/// verified" carry no signal at all. Green now appears only where it means
/// something.
abstract final class AppColors {
  /// Near-black, biased very slightly green — a chosen neutral, not #000.
  static const Color ink = Color(0xFF101614);

  /// App background. Cool near-white, deliberately not the cream everyone uses.
  static const Color paper = Color(0xFFF4F6F4);

  /// Cards and sheets sit above [paper].
  static const Color card = Color(0xFFFFFFFF);

  /// Hairline borders. Cards are defined by an edge, not a shadow.
  static const Color line = Color(0xFFE3E7E4);

  /// Secondary text.
  static const Color muted = Color(0xFF69736E);

  /// Money in, and verified-against-SMS. The only green in the app.
  static const Color credit = Color(0xFF14713C);

  /// Money out.
  static const Color debit = Color(0xFFA62B22);

  /// Not yet corroborated: AI-parsed, unmatched SMS, partial verification.
  static const Color pending = Color(0xFF8A5A00);

  static const Color creditWash = Color(0xFFE7F2EB);
  static const Color debitWash = Color(0xFFFBEBEA);
  static const Color pendingWash = Color(0xFFFDF3DF);
}

/// 4-point spacing scale. Everything in the app snaps to these.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Type roles.
///
/// Roboto (Flutter's built-in) throughout — the personality comes from the
/// scale and the settings, not from a novelty face. Every style that shows
/// digits uses tabular figures so columns of money line up exactly; without it
/// a 1 is narrower than a 7 and the column visibly wobbles.
abstract final class AppTextStyles {
  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  /// The headline number: a balance you are meant to read at a glance.
  static const TextStyle money = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w600,
    letterSpacing: -1,
    height: 1.05,
    fontFeatures: _tabular,
  );

  /// Money inside a list row.
  static const TextStyle moneyRow = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.2,
    fontFeatures: _tabular,
  );

  /// Money in a dense table (reports).
  static const TextStyle moneyCell = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    fontFeatures: _tabular,
  );

  /// Section eyebrows: "TODAY", "BRANCHES".
  static const TextStyle label = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.9,
    color: AppColors.muted,
  );

  /// FT reference numbers.
  ///
  /// A bundled face, not `fontFamily: 'monospace'` — that resolves to whatever
  /// the device happens to ship, so a reference could render differently on
  /// two phones. References are identifiers; they should look identical
  /// everywhere.
  static const TextStyle mono = TextStyle(
    fontFamily: 'DejaVuSansMono',
    fontSize: 12,
    letterSpacing: 0,
    fontFeatures: _tabular,
  );
}

class AppTheme {
  AppTheme._();

  /// Kept for the launcher icon and any seed-derived colours.
  static const Color seedColor = AppColors.credit;

  static ThemeData light() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: AppColors.credit,
          brightness: Brightness.light,
        ).copyWith(
          // Override the seeded tints: surfaces must stay neutral so green
          // reads as meaning rather than as background.
          surface: AppColors.paper,
          surfaceContainerLowest: AppColors.card,
          surfaceContainerLow: AppColors.card,
          surfaceContainer: AppColors.card,
          // Fills behind thumbnails and placeholders.
          surfaceContainerHigh: Color(0xFFEDEFEE),
          surfaceContainerHighest: Color(0xFFE8EBE9),
          onSurface: AppColors.ink,
          onSurfaceVariant: AppColors.muted,
          // Every greyscale role is pinned, not just some: whatever a screen
          // reaches for must land on a neutral. Anything left seeded comes back
          // green-tinted and quietly reintroduces the wallpaper problem.
          outline: AppColors.muted,
          outlineVariant: AppColors.line,
          primary: AppColors.credit,
          onPrimary: Colors.white,
          primaryContainer: AppColors.creditWash,
          onPrimaryContainer: AppColors.credit,
          error: AppColors.debit,
          onError: Colors.white,
          errorContainer: AppColors.debitWash,
          onErrorContainer: AppColors.debit,
        );

    final base = ThemeData(useMaterial3: true, colorScheme: scheme);

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.paper,
      textTheme: base.textTheme.apply(
        bodyColor: AppColors.ink,
        displayColor: AppColors.ink,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.paper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.ink,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: AppColors.ink),
      ),
      // Cards are defined by a hairline, not a drop shadow: a ledger is flat.
      cardTheme: CardThemeData(
        color: AppColors.card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.line),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.line,
        thickness: 1,
        space: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.card,
        indicatorColor: AppColors.creditWash,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? AppColors.credit
                : AppColors.muted,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? AppColors.credit
                : AppColors.muted,
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.credit,
        foregroundColor: Colors.white,
        elevation: 2,
        shape: CircleBorder(),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.credit,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink,
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: AppColors.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.card,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.line),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.card,
        selectedColor: AppColors.creditWash,
        side: const BorderSide(color: AppColors.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        labelStyle: const TextStyle(fontSize: 13, color: AppColors.ink),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.ink,
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

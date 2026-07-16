// App boot tests: the first-run onboarding gate, the 4-tab shell, and the
// dashboard's live-data wiring.
//
// These override the stream providers with plain values rather than booting a
// real Drift database. Drift's async work never completes inside testWidgets'
// fake-async zone (queries and close() deadlock), and DB behaviour is already
// covered by the Phase 2 DAO tests in test/data/database_test.dart. Here we
// only care that the UI renders what the providers emit.

import 'package:cbe_tracker/app/app.dart';
import 'package:cbe_tracker/app/theme.dart';
import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/database_provider.dart';
import 'package:cbe_tracker/features/branch_detail/branch_detail_providers.dart';
import 'package:cbe_tracker/features/dashboard/period.dart';
import 'package:cbe_tracker/features/reconcile/reconcile_providers.dart';
import 'package:cbe_tracker/features/reports/reports_providers.dart';
import 'package:cbe_tracker/services/report_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the day so the period providers resolve deterministically and no
/// midnight-rollover timer is left pending at the end of a test.
class _FixedToday extends Today {
  @override
  DateTime build() => DateTime(2026, 7, 15);
}

void main() {
  final bole = Branch(
    id: 1,
    name: 'Bole',
    archived: false,
    createdAt: DateTime(2026, 7, 15),
  );

  /// Builds the app with every DB-backed stream stubbed.
  Widget app({
    List<Branch> branches = const [],
    int totalCents = 0,
    int todayDeltaCents = 0,
    int branchBalanceCents = 0,
    int branchTodayCount = 0,
    int unmatchedSms = 0,
  }) {
    return ProviderScope(
      overrides: [
        // Deterministic day → the default all-time period, no rollover timer.
        todayProvider.overrideWith(_FixedToday.new),
        activeBranchesProvider.overrideWithValue(AsyncValue.data(branches)),
        totalBalanceCentsProvider.overrideWithValue(AsyncValue.data(totalCents)),
        todayDeltaCentsProvider.overrideWithValue(
          AsyncValue.data(todayDeltaCents),
        ),
        // The dashboard headline reads the period figure; at the default
        // all-time window it equals the total balance.
        periodDeltaCentsProvider.overrideWithValue(
          AsyncValue.data(totalCents),
        ),
        unmatchedSmsCountProvider.overrideWithValue(
          AsyncValue.data(unmatchedSms),
        ),
        // The test host isn't Android, so the real provider would report the
        // cross-check as off and the strip would show its muted variant.
        smsCrossCheckActiveProvider.overrideWithValue(true),
        branchBalanceCentsProvider(
          bole.id,
        ).overrideWithValue(AsyncValue.data(branchBalanceCents)),
        branchPeriodDeltaProvider(
          bole.id,
        ).overrideWithValue(AsyncValue.data(branchBalanceCents)),
        branchPeriodCountProvider(
          bole.id,
        ).overrideWithValue(AsyncValue.data(branchTodayCount)),
        // Phase 7's branch detail is a real screen now, so its stream needs
        // stubbing too or tapping through hits the database.
        branchTransactionsProvider(
          bole.id,
        ).overrideWithValue(const AsyncValue.data([])),
        // Phase 8's Reports tab likewise.
        dailyReportProvider.overrideWithValue(
          AsyncValue.data(
            DailyReport(
              day: DateTime(2026, 7, 15),
              branches: const [],
              footer: const ReconciliationFooter(
                personalCount: 0,
                unresolvedCount: 0,
                crossChecked: true,
              ),
            ),
          ),
        ),
      ],
      // No notification plugin or database in widget tests.
      child: const CbeTrackerApp(bootstrap: false),
    );
  }

  group('first-run gate (branch count, not SharedPreferences)', () {
    testWidgets('zero branches → onboarding, not the shell', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('Add your branches'), findsOneWidget);
      expect(find.text('Reconcile'), findsNothing);
    });

    testWidgets('Done is disabled while there are no branches', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      final done = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Done'),
      );
      expect(done.onPressed, isNull);
    });

    testWidgets('a branch existing lets the app reach the dashboard', (
      tester,
    ) async {
      await tester.pumpWidget(app(branches: [bole]));
      await tester.pumpAndSettle();

      expect(find.text('Add your branches'), findsNothing);
      expect(find.widgetWithText(AppBar, 'CBE Tracker'), findsOneWidget);
    });
  });

  group('dashboard', () {
    testWidgets('boots with 3 tabs — adding is the FAB, not a tab', (
      tester,
    ) async {
      await tester.pumpWidget(app(branches: [bole]));
      await tester.pumpAndSettle();

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Reconcile'), findsOneWidget);
      expect(find.text('Reports'), findsOneWidget);
      // Tabs are destinations; adding is an action. The old 'Add' tab led to a
      // dead placeholder because there was no place for it to go.
      expect(find.widgetWithText(NavigationDestination, 'Add'), findsNothing);
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets('total card and branch card show formatted balances', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(branches: [bole], totalCents: 14520000, branchBalanceCents: 14520000),
      );
      await tester.pumpAndSettle();

      // The default window is all-time, so the headline reads its label and
      // the figure is a plain balance (unsigned) in both the total and the row.
      expect(find.text('ALL TIME'), findsOneWidget);
      expect(find.text('ETB 145,200.00'), findsNWidgets(2)); // total + row
      expect(find.text('Bole'), findsOneWidget);
    });

    testWidgets('branch card pluralises its count', (tester) async {
      await tester.pumpWidget(app(branches: [bole], branchTodayCount: 1));
      await tester.pumpAndSettle();
      expect(find.text('1 transaction'), findsOneWidget);

      await tester.pumpWidget(app(branches: [bole], branchTodayCount: 3));
      await tester.pumpAndSettle();
      expect(find.text('3 transactions'), findsOneWidget);
    });

    testWidgets('today delta is hidden at zero', (tester) async {
      await tester.pumpWidget(app(branches: [bole]));
      await tester.pumpAndSettle();

      // The delta line is omitted entirely rather than reading "ETB 0.00".
      expect(find.textContaining('ETB 0.00 today'), findsNothing);
      expect(find.textContaining('+ ETB'), findsNothing);
      expect(find.textContaining('− ETB'), findsNothing);
    });

    testWidgets('positive delta renders green with a plus', (tester) async {
      await tester.pumpWidget(app(branches: [bole], todayDeltaCents: 500000));
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.text('+ ETB 5,000.00 today'));
      expect(text.style?.color, AppColors.credit);
    });

    testWidgets('negative delta renders red with a minus sign', (tester) async {
      await tester.pumpWidget(app(branches: [bole], todayDeltaCents: -500000));
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.text('− ETB 5,000.00 today'));
      expect(text.style?.color, AppColors.debit);
    });

    // The reconciliation strip is always present and switches state, rather
    // than appearing only on trouble (§FR-8 says "banner when unmatched SMS
    // exist"). Deliberate: the app's whole job is answering "did anything slip
    // through?", and a hidden banner answers nothing — you can't tell "all
    // clear" from "the check never ran".
    testWidgets('strip confirms all-clear when nothing is waiting', (
      tester,
    ) async {
      await tester.pumpWidget(app(branches: [bole]));
      await tester.pumpAndSettle();

      expect(
        find.text('Every CBE message today has a screenshot'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });

    testWidgets('strip warns, and pluralises, when payments are waiting', (
      tester,
    ) async {
      await tester.pumpWidget(app(branches: [bole], unmatchedSms: 3));
      await tester.pumpAndSettle();

      expect(
        find.text('3 payments texted today have no screenshot'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsNothing);

      await tester.pumpWidget(app(branches: [bole], unmatchedSms: 1));
      await tester.pumpAndSettle();
      expect(
        find.text('1 payment texted today has no screenshot'),
        findsOneWidget,
      );
    });

    testWidgets('switching to the Reports tab shows Reports', (tester) async {
      await tester.pumpWidget(app(branches: [bole]));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(NavigationDestination, 'Reports'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'Reports'), findsOneWidget);
    });

    testWidgets('FAB opens the add-method sheet', (tester) async {
      await tester.pumpWidget(app(branches: [bole]));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Single screenshot'), findsOneWidget);
      expect(find.text('Bulk upload'), findsOneWidget);
    });

    testWidgets('tapping a branch card opens branch detail', (tester) async {
      await tester.pumpWidget(app(branches: [bole]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Bole'));
      await tester.pumpAndSettle();

      // The real screen titles itself with the branch name (Phase 7 replaced
      // the placeholder), and shows the empty state for a branch with no
      // transactions.
      expect(find.widgetWithText(AppBar, 'Bole'), findsOneWidget);
      expect(find.text('No transactions yet'), findsOneWidget);
    });
  });
}

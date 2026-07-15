// App boot tests: the first-run onboarding gate, the 4-tab shell, and the
// dashboard's live-data wiring.
//
// These override the stream providers with plain values rather than booting a
// real Drift database. Drift's async work never completes inside testWidgets'
// fake-async zone (queries and close() deadlock), and DB behaviour is already
// covered by the Phase 2 DAO tests in test/data/database_test.dart. Here we
// only care that the UI renders what the providers emit.

import 'package:cbe_tracker/app/app.dart';
import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/database_provider.dart';
import 'package:cbe_tracker/features/branch_detail/branch_detail_providers.dart';
import 'package:cbe_tracker/features/reconcile/reconcile_providers.dart';
import 'package:cbe_tracker/features/reports/reports_providers.dart';
import 'package:cbe_tracker/services/report_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
        activeBranchesProvider.overrideWithValue(AsyncValue.data(branches)),
        totalBalanceCentsProvider.overrideWithValue(AsyncValue.data(totalCents)),
        todayDeltaCentsProvider.overrideWithValue(
          AsyncValue.data(todayDeltaCents),
        ),
        unmatchedSmsCountProvider.overrideWithValue(
          AsyncValue.data(unmatchedSms),
        ),
        branchBalanceCentsProvider(
          bole.id,
        ).overrideWithValue(AsyncValue.data(branchBalanceCents)),
        branchTodayCountProvider(
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
              ),
            ),
          ),
        ),
      ],
      // No notification plugin or database in widget tests.
      child: const CbeTrackerApp(bootstrapReminder: false),
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
    testWidgets('boots with 4 tabs', (tester) async {
      await tester.pumpWidget(app(branches: [bole]));
      await tester.pumpAndSettle();

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Add'), findsOneWidget);
      expect(find.text('Reconcile'), findsOneWidget);
      expect(find.text('Reports'), findsOneWidget);
    });

    testWidgets('total card and branch card show formatted balances', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(branches: [bole], totalCents: 14520000, branchBalanceCents: 14520000),
      );
      await tester.pumpAndSettle();

      expect(find.text('Total balance'), findsOneWidget);
      expect(find.text('ETB 145,200.00'), findsNWidgets(2)); // total + card
      expect(find.text('Bole'), findsOneWidget);
    });

    testWidgets('branch card pluralises today\'s count', (tester) async {
      await tester.pumpWidget(app(branches: [bole], branchTodayCount: 1));
      await tester.pumpAndSettle();
      expect(find.text('1 transaction today'), findsOneWidget);

      await tester.pumpWidget(app(branches: [bole], branchTodayCount: 3));
      await tester.pumpAndSettle();
      expect(find.text('3 transactions today'), findsOneWidget);
    });

    testWidgets('today delta is hidden at zero', (tester) async {
      await tester.pumpWidget(app(branches: [bole]));
      await tester.pumpAndSettle();

      expect(find.textContaining('today'), findsOneWidget); // only the card line
      expect(find.textContaining('ETB 0.00 today'), findsNothing);
    });

    testWidgets('positive delta renders green with a plus', (tester) async {
      await tester.pumpWidget(app(branches: [bole], todayDeltaCents: 500000));
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.text('+ ETB 5,000.00 today'));
      expect(text.style?.color, const Color(0xFF1B7A43));
    });

    testWidgets('negative delta renders red with a minus sign', (tester) async {
      await tester.pumpWidget(app(branches: [bole], todayDeltaCents: -500000));
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.text('− ETB 5,000.00 today'));
      final scheme = Theme.of(
        tester.element(find.text('− ETB 5,000.00 today')),
      ).colorScheme;
      expect(text.style?.color, scheme.error);
    });

    testWidgets('SMS banner hidden at 0, shown above 0', (tester) async {
      await tester.pumpWidget(app(branches: [bole]));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);

      await tester.pumpWidget(app(branches: [bole], unmatchedSms: 3));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(
        find.text('3 SMS not matched to a screenshot today'),
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

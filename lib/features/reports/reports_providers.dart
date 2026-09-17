/// Providers for the Reports tab (§FR-6).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database_provider.dart';
import '../../services/notification_service.dart';
import '../../services/pdf_service.dart';
import '../../services/report_service.dart';
import 'daily_bars.dart';

final reportServiceProvider = Provider<ReportService>(
  (ref) => ReportService(
    branchDao: ref.watch(branchDaoProvider),
    transactionDao: ref.watch(transactionDaoProvider),
  ),
);

final pdfServiceProvider = Provider<PdfService>((ref) => PdfService());

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService(),
);

/// The day the Reports tab is showing. Defaults to today.
class ReportDay extends Notifier<DateTime> {
  @override
  DateTime build() {
    // Seed from the live day, not a fresh `DateTime.now()`, so a report opened
    // after midnight on an app that was left running lands on the real today.
    // read, not watch: once she's on the tab, the roll shouldn't yank her off a
    // day she's looking at — she moves it herself.
    return ref.read(todayProvider);
  }

  void select(DateTime day) => state = DateTime(day.year, day.month, day.day);
}

final reportDayProvider = NotifierProvider<ReportDay, DateTime>(ReportDay.new);

/// The report for the selected day.
///
/// Recomputed from the transactions table on every read (§FR-6), and re-run
/// whenever the ledger changes, so the tab can't show stale figures.
final dailyReportProvider = FutureProvider<DailyReport>((ref) {
  ref.watch(activeBranchesProvider);
  ref.watch(totalBalanceCentsProvider);
  return ref
      .watch(reportServiceProvider)
      .dailyReport(ref.watch(reportDayProvider));
});

/// The seven days ending on the selected day, bucketed for the bar chart.
/// Live: a save anywhere in the window moves its bar.
final dailyBarsProvider = StreamProvider.autoDispose<List<DayTotals>>((ref) {
  final day = ref.watch(reportDayProvider);
  return ref
      .watch(transactionDaoProvider)
      .watchLedgerInRange(chartWindowStart(day), chartWindowEnd(day))
      .map((entries) => totalsByDay(entries, day));
});

/// The configured reminder, or null when switched off.
final reminderTimeProvider = StreamProvider<ReminderTime?>((ref) {
  return ref.watch(settingsDaoProvider).watchReminderTime().map((raw) {
    // Never configured → the 18:00 default is in effect.
    if (raw == null) return ReminderTime.defaultTime;
    if (raw == 'off') return null;
    return ReminderTime.parse(raw) ?? ReminderTime.defaultTime;
  });
});

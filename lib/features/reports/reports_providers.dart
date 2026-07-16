/// Providers for the Reports tab (§FR-6).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database_provider.dart';
import '../../services/notification_service.dart';
import '../../services/pdf_service.dart';
import '../../services/report_service.dart';
import '../reconcile/reconcile_providers.dart';

final reportServiceProvider = Provider<ReportService>(
  (ref) => ReportService(
    branchDao: ref.watch(branchDaoProvider),
    transactionDao: ref.watch(transactionDaoProvider),
    smsDao: ref.watch(smsDaoProvider),
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

/// A tick whenever the shown day's SMS change — a new message, a reconcile
/// match, an ignore. The report's balances already refresh through
/// [totalBalanceCentsProvider]; this covers the reconciliation figures, which
/// move without any balance changing.
final _reportSmsSignalProvider = StreamProvider.autoDispose<int>((ref) {
  final day = ref.watch(reportDayProvider);
  return ref.watch(smsDaoProvider).watchUnmatchedCountForDay(day);
});

/// The report for the selected day.
///
/// Recomputed from the transactions table on every read (§FR-6), and re-run
/// when the ledger OR the day's SMS change, so the tab can't show stale figures.
final dailyReportProvider = FutureProvider<DailyReport>((ref) {
  ref.watch(activeBranchesProvider);
  ref.watch(totalBalanceCentsProvider);
  ref.watch(_reportSmsSignalProvider);
  return ref.watch(reportServiceProvider).dailyReport(
    ref.watch(reportDayProvider),
    // The report (and its PDF) must say when the SMS cross-check never ran
    // rather than presenting "0 unresolved" as a clean bill.
    crossChecked: ref.watch(smsCrossCheckActiveProvider),
  );
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

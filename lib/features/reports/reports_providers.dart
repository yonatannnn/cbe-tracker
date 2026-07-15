/// Providers for the Reports tab (§FR-6).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database_provider.dart';
import '../../services/notification_service.dart';
import '../../services/pdf_service.dart';
import '../../services/report_service.dart';

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
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  void select(DateTime day) => state = DateTime(day.year, day.month, day.day);
}

final reportDayProvider = NotifierProvider<ReportDay, DateTime>(ReportDay.new);

/// The report for the selected day.
///
/// Recomputed from the transactions table on every read (§FR-6), and re-run
/// when the ledger changes so the tab can't show stale figures.
final dailyReportProvider = FutureProvider<DailyReport>((ref) {
  ref.watch(activeBranchesProvider);
  ref.watch(totalBalanceCentsProvider);
  return ref.watch(reportServiceProvider).dailyReport(
    ref.watch(reportDayProvider),
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

/// Reconcile providers (§FR-5).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/daos/settings_dao.dart';
import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';
import '../../services/reconcile_service.dart';
import '../../services/sms_service.dart';

final reconcileServiceProvider = Provider<ReconcileService>(
  (ref) => ReconcileService(
    smsDao: ref.watch(smsDaoProvider),
    transactionDao: ref.watch(transactionDaoProvider),
  ),
);

/// Android → real reader; everything else → no-op (§6).
final smsServiceProvider = Provider<SmsService>(
  (ref) => createSmsService(
    db: ref.watch(appDatabaseProvider),
    reconciler: ref.watch(reconcileServiceProvider),
  ),
);

/// The day the Reconcile tab is showing. Defaults to today.
///
/// A Notifier rather than the legacy StateProvider, which Riverpod 3 moved to
/// `legacy.dart`.
class ReconcileDay extends Notifier<DateTime> {
  @override
  DateTime build() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// Always normalizes to midnight — the queries bracket a calendar day.
  void select(DateTime day) => state = DateTime(day.year, day.month, day.day);
}

final reconcileDayProvider = NotifierProvider<ReconcileDay, DateTime>(
  ReconcileDay.new,
);

/// Count of today's unmatched, un-ignored SMS — drives the dashboard banner.
/// Replaces the Phase 3 stub that always returned 0.
final unmatchedSmsCountProvider = StreamProvider<int>(
  (ref) => ref.watch(smsDaoProvider).watchUnmatchedCountForDay(DateTime.now()),
);

/// Unmatched SMS for the selected day — the reconcile list.
final unmatchedSmsForDayProvider = StreamProvider<List<SmsTransaction>>(
  (ref) => ref
      .watch(smsDaoProvider)
      .watchUnmatchedForDay(ref.watch(reconcileDayProvider)),
);

/// Ignored SMS for the selected day — the collapsed section.
final ignoredSmsForDayProvider = StreamProvider<List<SmsTransaction>>(
  (ref) => ref
      .watch(smsDaoProvider)
      .watchIgnoredForDay(ref.watch(reconcileDayProvider)),
);

/// Received / matched counts for the summary cards.
final smsCountsForDayProvider = FutureProvider<DayCounts>((ref) {
  // Re-runs when the ledger changes, so the cards track the list.
  ref.watch(unmatchedSmsForDayProvider);
  return ref
      .watch(smsDaoProvider)
      .countsForDay(ref.watch(reconcileDayProvider));
});

/// Where the user got to with the SMS permission: unasked / granted / skipped.
final smsPermissionStateProvider = StreamProvider<SmsPermissionState>(
  (ref) => ref.watch(settingsDaoProvider).watchSmsPermissionState(),
);

/// Whether a screenshot's reference already has a matching CBE SMS — shows the
/// "Verified against SMS" line on the confirm screen. Replaces the Phase 4
/// stub that always returned null.
final smsVerifiedProvider = FutureProvider.family<SmsTransaction?, String?>((
  ref,
  reference,
) async {
  if (reference == null || reference.isEmpty) return null;
  return ref.watch(smsDaoProvider).findByReference(reference);
});

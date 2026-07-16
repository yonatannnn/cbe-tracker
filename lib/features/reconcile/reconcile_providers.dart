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
///
/// Watches [todayProvider] rather than capturing `DateTime.now()` once: the
/// banner is the app's headline claim ("every CBE message today has a
/// screenshot"), and left frozen at launch it evaluated that against yesterday
/// every midnight, hiding the day's real unmatched payments.
final unmatchedSmsCountProvider = StreamProvider<int>((ref) {
  final today = ref.watch(todayProvider);
  return ref.watch(smsDaoProvider).watchUnmatchedCountForDay(today);
});

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

/// Whether the SMS cross-check is actually running: an Android device AND
/// permission granted. Every surface that claims "verified" or "all clear"
/// must check this first — on iOS, or after "skip, screenshots only", those
/// claims would describe a check that structurally never runs, and a false
/// green tick is the most dangerous thing this app can show.
final smsCrossCheckActiveProvider = Provider<bool>((ref) {
  if (!ref.watch(smsServiceProvider).isSupported) return false;
  return ref.watch(smsPermissionStateProvider).value ==
      SmsPermissionState.granted;
});

/// Where the user got to with the SMS permission: unasked / granted / skipped.
final smsPermissionStateProvider = StreamProvider<SmsPermissionState>(
  (ref) => ref.watch(settingsDaoProvider).watchSmsPermissionState(),
);

/// Whether a screenshot's reference already has a matching CBE SMS — shows the
/// "Verified against SMS" line on the confirm screen. Replaces the Phase 4
/// stub that always returned null.
/// autoDispose: keyed by reference STRING — without it every reference ever
/// confirmed stays cached for the whole session.
final smsVerifiedProvider = FutureProvider.autoDispose
    .family<SmsTransaction?, String?>((ref, reference) async {
      if (reference == null || reference.isEmpty) return null;
      return ref.watch(smsDaoProvider).findByReference(reference);
    });

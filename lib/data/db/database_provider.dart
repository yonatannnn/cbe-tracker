/// Riverpod wiring for the database layer (§6).
///
/// The UI consumes these streams with `ref.watch` — Drift pushes new values on
/// every write, so balances update live with no manual polling.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'daos/branch_dao.dart';
import 'daos/settings_dao.dart';
import 'daos/sms_dao.dart';
import 'daos/transaction_dao.dart';
import 'database.dart';

/// The single app-wide Drift database.
///
/// Overridden in tests with `AppDatabase.forTesting(NativeDatabase.memory())`.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final branchDaoProvider = Provider<BranchDao>(
  (ref) => ref.watch(appDatabaseProvider).branchDao,
);

final transactionDaoProvider = Provider<TransactionDao>(
  (ref) => ref.watch(appDatabaseProvider).transactionDao,
);

final smsDaoProvider = Provider<SmsDao>(
  (ref) => ref.watch(appDatabaseProvider).smsDao,
);

final settingsDaoProvider = Provider<SettingsDao>(
  (ref) => ref.watch(appDatabaseProvider).settingsDao,
);

/// Live list of non-archived branches. Also drives the first-run gate: an
/// empty list means onboarding (§8 Phase 3 — count, not SharedPreferences).
final activeBranchesProvider = StreamProvider<List<Branch>>(
  (ref) => ref.watch(branchDaoProvider).watchActiveBranches(),
);

/// Live total balance across active branches, in cents.
final totalBalanceCentsProvider = StreamProvider<int>(
  (ref) => ref.watch(transactionDaoProvider).watchTotalBalanceCents(),
);

/// Live balance for one branch, in cents. The branch's true standing total —
/// the dashboard's period-scoped figures live in features/dashboard/period.dart.
/// autoDispose: keyed per visited branch, and each retained entry is a live
/// SUM re-run on every transaction write.
final branchBalanceCentsProvider = StreamProvider.autoDispose.family<int, int>(
  (ref, branchId) =>
      ref.watch(transactionDaoProvider).watchBalanceCents(branchId),
);

/// The current calendar day, refreshed as the day actually rolls over.
///
/// Lives here — the neutral providers hub — rather than in a feature, because
/// the dashboard, the reports tab and the reconcile banner all read it. It
/// ticks at the next local midnight and is refreshed on app resume, so nothing
/// downstream has to call `DateTime.now()` and freeze the day at launch.
class Today extends Notifier<DateTime> {
  Timer? _timer;

  @override
  DateTime build() {
    ref.onDispose(() => _timer?.cancel());
    _scheduleRollover();
    return _dateOnly(DateTime.now());
  }

  /// Re-reads the wall clock; a no-op when the day is unchanged, so calling it
  /// on every resume is cheap.
  void refresh() {
    final today = _dateOnly(DateTime.now());
    if (today != state) state = today;
    _scheduleRollover();
  }

  void _scheduleRollover() {
    _timer?.cancel();
    final now = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    _timer = Timer(nextMidnight.difference(now), refresh);
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
}

final todayProvider = NotifierProvider<Today, DateTime>(Today.new);

/// Live credits − debits for today across active branches, in cents. Drives the
/// "+X today" line under the all-time balance; watches [todayProvider] so it
/// rolls with the day instead of freezing at launch.
final todayDeltaCentsProvider = StreamProvider<int>((ref) {
  final today = ref.watch(todayProvider);
  final tomorrow = today.add(const Duration(days: 1));
  return ref
      .watch(transactionDaoProvider)
      .watchDeltaCentsInRange(today, tomorrow);
});

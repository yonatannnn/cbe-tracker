/// Riverpod wiring for the database layer (§6).
///
/// The UI consumes these streams with `ref.watch` — Drift pushes new values on
/// every write, so balances update live with no manual polling.
library;

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

/// Live credits − debits for today across active branches, in cents.
final todayDeltaCentsProvider = StreamProvider<int>(
  (ref) => ref.watch(transactionDaoProvider).watchDayDeltaCents(DateTime.now()),
);

/// Live balance for one branch, in cents.
final branchBalanceCentsProvider = StreamProvider.family<int, int>(
  (ref, branchId) =>
      ref.watch(transactionDaoProvider).watchBalanceCents(branchId),
);

/// Live count of a branch's transactions today.
final branchTodayCountProvider = StreamProvider.family<int, int>(
  (ref, branchId) =>
      ref.watch(transactionDaoProvider).watchDayCount(branchId, DateTime.now()),
);

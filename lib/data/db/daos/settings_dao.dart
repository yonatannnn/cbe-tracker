import 'package:drift/drift.dart';

import '../database.dart';
import '../tables.dart';

part 'settings_dao.g.dart';

/// Small key-value settings store. Currently only remembers the most recently
/// used branch so the add flow can pre-select it (§FR-2).
@DriftAccessor(tables: [AppSettings])
class SettingsDao extends DatabaseAccessor<AppDatabase>
    with _$SettingsDaoMixin {
  SettingsDao(super.db);

  static const _lastBranchKey = 'last_branch_id';
  static const _reminderKey = 'report_reminder_time';
  static const _reminderLastKey = 'report_reminder_time_last';
  static const _cloudBackupKey = 'cloud_last_backup';
  static const _ownerAccountKey = 'owner_cbe_account_suffix';

  Future<String?> _get(String key) async {
    final row = await (select(
      appSettings,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> _set(String key, String value) => into(appSettings).insert(
    AppSettingsCompanion.insert(key: key, value: value),
    mode: InsertMode.insertOrReplace,
  );

  /// The branch used for the last saved transaction, or null on first use.
  Future<int?> getLastBranchId() async {
    final raw = await _get(_lastBranchKey);
    return raw == null ? null : int.tryParse(raw);
  }

  Future<void> setLastBranchId(int branchId) =>
      _set(_lastBranchKey, branchId.toString());

  /// Live view of the last-used branch, so the chip picker re-selects it.
  Stream<int?> watchLastBranchId() {
    return (select(appSettings)..where((s) => s.key.equals(_lastBranchKey)))
        .watchSingleOrNull()
        .map((row) => row == null ? null : int.tryParse(row.value));
  }

  /// The daily report reminder, as "HH:mm". Null = off.
  ///
  /// Absent means "never configured", which the caller treats as the 18:00
  /// default (§FR-6); the literal string 'off' means the user turned it off.
  Stream<String?> watchReminderTime() {
    return (select(appSettings)..where((s) => s.key.equals(_reminderKey)))
        .watchSingleOrNull()
        .map((row) => row?.value);
  }

  Future<String?> getReminderTime() async => _get(_reminderKey);

  /// Switching off remembers the time it had, so switching back on restores
  /// her 20:00 instead of silently resetting to the 18:00 default.
  Future<void> setReminderTime(String? value) async {
    if (value == null) {
      final current = await _get(_reminderKey);
      if (current != null && current != 'off') {
        await _set(_reminderLastKey, current);
      }
      await _set(_reminderKey, 'off');
      return;
    }
    await _set(_reminderKey, value);
  }

  /// The time the reminder had before it was last switched off ("HH:mm").
  Future<String?> getLastReminderTime() => _get(_reminderLastKey);

  /// The last digits of her CBE account ("7737"), or null when never set.
  ///
  /// Decides direction on receipts that show both sides of a transfer (the
  /// CBE app receipt, the USSD confirmation): her account as receiver → a
  /// credit, as sender → a debit. Without it those rows come back for review.
  Stream<String?> watchOwnerAccountSuffix() {
    return (select(appSettings)..where((s) => s.key.equals(_ownerAccountKey)))
        .watchSingleOrNull()
        .map((row) => row?.value.isEmpty ?? true ? null : row!.value);
  }

  Future<String?> getOwnerAccountSuffix() async {
    final raw = await _get(_ownerAccountKey);
    return raw == null || raw.isEmpty ? null : raw;
  }

  Future<void> setOwnerAccountSuffix(String? digits) =>
      _set(_ownerAccountKey, digits ?? '');

  /// When the last successful cloud backup completed, or null if never.
  ///
  /// Stored as ISO-8601; the automatic upload compares it against now to decide
  /// whether a fresh backup is due (Phase 10).
  Future<DateTime?> getLastCloudBackup() async {
    final raw = await _get(_cloudBackupKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setLastCloudBackup(DateTime when) =>
      _set(_cloudBackupKey, when.toIso8601String());
}

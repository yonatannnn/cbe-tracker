import 'package:drift/drift.dart';

import '../database.dart';
import '../tables.dart';

part 'settings_dao.g.dart';

/// Small key-value settings store. Currently only remembers the most recently
/// used branch so the add flow can pre-select it (§FR-2).
@DriftAccessor(tables: [AppSettings])
class SettingsDao extends DatabaseAccessor<AppDatabase> with _$SettingsDaoMixin {
  SettingsDao(super.db);

  static const _lastBranchKey = 'last_branch_id';
  static const _smsStateKey = 'sms_permission_state';
  static const _reminderKey = 'report_reminder_time';

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

  /// Where the user got to with the SMS permission (§FR-4).
  ///
  /// Deliberately tri-state. A plain "skipped" bool can't tell "never asked"
  /// from "granted"; and inferring it from whether any SMS exist is wrong too,
  /// because a first sync pulls HISTORICAL messages — today's count can be 0
  /// with permission granted, stranding the user on the explainer forever.
  Stream<SmsPermissionState> watchSmsPermissionState() {
    return (select(appSettings)..where((s) => s.key.equals(_smsStateKey)))
        .watchSingleOrNull()
        .map(
          (row) => switch (row?.value) {
            'granted' => SmsPermissionState.granted,
            'skipped' => SmsPermissionState.skipped,
            _ => SmsPermissionState.unasked,
          },
        );
  }

  Future<void> setSmsPermissionState(SmsPermissionState state) =>
      _set(_smsStateKey, state.name);

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

  Future<void> setReminderTime(String? value) =>
      _set(_reminderKey, value ?? 'off');
}

/// Tri-state so "never asked" is distinguishable from granted/skipped.
enum SmsPermissionState { unasked, granted, skipped }

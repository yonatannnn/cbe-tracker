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
}

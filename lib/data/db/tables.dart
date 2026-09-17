import 'package:drift/drift.dart';

import '../../core/parser/cbe_parser.dart';

/// Where a transaction came from (§3: source CHECK IN screenshot/sms/manual).
///
/// `sms` is kept only so rows written by builds that still read CBE SMS keep
/// decoding; nothing creates it any more.
enum TxSource { screenshot, sms, manual }

/// Branches. Balance is derived from [Transactions], never stored (§FR-1).
@DataClassName('Branch')
class Branches extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// Screenshot/manual transactions — the ONLY source of balances (§3).
class Transactions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get branchId => integer().references(Branches, #id)();

  /// Money is integer cents everywhere — never a double column (CLAUDE.md).
  IntColumn get amountCents => integer()();

  /// Stored as TEXT ('credit'/'debit') via the enum converter.
  TextColumn get type => textEnum<TxType>()();

  /// FT reference number — UNIQUE, NOT NULL; the duplicate guard (§FR-2).
  TextColumn get reference => text().unique()();

  TextColumn get screenshotPath => text().nullable()();
  TextColumn get ocrText => text().nullable()();

  /// Stored as TEXT ('screenshot'/'sms'/'manual') via the enum converter.
  TextColumn get source => textEnum<TxSource>()();

  DateTimeColumn get transactionDate => dateTime()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// Tiny key-value store for app preferences (e.g. the most recently used
/// branch). Kept in SQLite so we don't pull in a package beyond §5.
@DataClassName('AppSetting')
class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

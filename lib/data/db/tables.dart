import 'package:drift/drift.dart';

import '../../core/parser/cbe_parser.dart';

/// Where a transaction came from (§3: source CHECK IN screenshot/sms/manual).
enum TxSource { screenshot, sms, manual }

/// Branches. Balance is derived from [Transactions], never stored (§FR-1).
@DataClassName('Branch')
class Branches extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();
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
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();
}

/// CBE SMS bodies the shared parser could NOT read.
///
/// SMS is raw digital text, so a failure here means the parser is missing a
/// real format — exactly what happened with the app-receipt shape in Phase 4.
/// Logging them locally lets us harvest real fixtures instead of guessing.
/// Never shown in the UI; never affects balances.
///
/// Deduped on (body, receivedAt): without this the log re-records every
/// message on every sync — 606 rows for 192 real messages on the first live
/// run, which made the "how much do we parse?" numbers read ~2x better than
/// reality.
@DataClassName('SmsDebugEntry')
@TableIndex(name: 'sms_debug_unique', columns: {#body, #receivedAt}, unique: true)
class SmsDebugLog extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get address => text()();
  TextColumn get body => text()();
  DateTimeColumn get receivedAt => dateTime()();

  /// The ParseException message, for triage.
  TextColumn get reason => text().nullable()();
  DateTimeColumn get loggedAt => dateTime().withDefault(currentDateAndTime)();
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

/// Shadow ledger from CBE SMS — NEVER affects balances (§3, §FR-4).
///
/// Deduped on (smsBody, receivedAt) as well as on [reference].
///
/// The reference alone is NOT enough: modern CBE messages carry no FT number
/// at all (133 of 271 in the live inbox), and SQLite's UNIQUE permits any
/// number of NULLs — so re-syncing the inbox would insert every one of them
/// again. Two genuinely distinct messages sharing a body AND a timestamp to
/// the second is not a real scenario.
@TableIndex(
  name: 'sms_body_time_unique',
  columns: {#smsBody, #receivedAt},
  unique: true,
)
class SmsTransactions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get amountCents => integer()();

  /// Nullable: an SMS may be too malformed to classify.
  TextColumn get type => textEnum<TxType>().nullable()();

  /// UNIQUE but nullable — malformed OCR/SMS refs are allowed (multiple NULLs
  /// coexist under SQLite UNIQUE).
  TextColumn get reference => text().nullable().unique()();

  TextColumn get smsBody => text()();
  DateTimeColumn get receivedAt => dateTime()();

  /// Set when reconciled against a real transaction (§FR-5).
  IntColumn get matchedTransactionId =>
      integer().nullable().references(Transactions, #id)();

  BoolColumn get ignored => boolean().withDefault(const Constant(false))();
}

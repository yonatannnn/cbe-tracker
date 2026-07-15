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

/// Shadow ledger from CBE SMS — NEVER affects balances (§3, §FR-4).
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

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sms_dao.dart';

// ignore_for_file: type=lint
mixin _$SmsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BranchesTable get branches => attachedDatabase.branches;
  $TransactionsTable get transactions => attachedDatabase.transactions;
  $SmsTransactionsTable get smsTransactions => attachedDatabase.smsTransactions;
  $SmsDebugLogTable get smsDebugLog => attachedDatabase.smsDebugLog;
  SmsDaoManager get managers => SmsDaoManager(this);
}

class SmsDaoManager {
  final _$SmsDaoMixin _db;
  SmsDaoManager(this._db);
  $$BranchesTableTableManager get branches =>
      $$BranchesTableTableManager(_db.attachedDatabase, _db.branches);
  $$TransactionsTableTableManager get transactions =>
      $$TransactionsTableTableManager(_db.attachedDatabase, _db.transactions);
  $$SmsTransactionsTableTableManager get smsTransactions =>
      $$SmsTransactionsTableTableManager(
        _db.attachedDatabase,
        _db.smsTransactions,
      );
  $$SmsDebugLogTableTableManager get smsDebugLog =>
      $$SmsDebugLogTableTableManager(_db.attachedDatabase, _db.smsDebugLog);
}

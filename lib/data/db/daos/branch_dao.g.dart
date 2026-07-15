// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'branch_dao.dart';

// ignore_for_file: type=lint
mixin _$BranchDaoMixin on DatabaseAccessor<AppDatabase> {
  $BranchesTable get branches => attachedDatabase.branches;
  $TransactionsTable get transactions => attachedDatabase.transactions;
  BranchDaoManager get managers => BranchDaoManager(this);
}

class BranchDaoManager {
  final _$BranchDaoMixin _db;
  BranchDaoManager(this._db);
  $$BranchesTableTableManager get branches =>
      $$BranchesTableTableManager(_db.attachedDatabase, _db.branches);
  $$TransactionsTableTableManager get transactions =>
      $$TransactionsTableTableManager(_db.attachedDatabase, _db.transactions);
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/repositories/transaction_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fakes.dart';

void main() {
  sqfliteFfiInit();
  final factory = databaseFactoryFfiNoIsolate;

  late Directory dir;
  late String legacyPath;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('money_mate_accounts');
    await factory.setDatabasesPath(dir.path);
    legacyPath = p.join(dir.path, AppConstants.databaseName);
  });

  tearDown(() => dir.delete(recursive: true));

  /// Creates the single shared database of older releases with one
  /// transaction, synchronised with [owner] (null: never synchronised).
  Future<void> createLegacy({String? owner}) async {
    final legacy = await AppDatabase.openAtPath(factory, legacyPath);
    await SqliteTransactionRepository(
      legacy,
    ).insert(tx(id: 'old', amountMinor: 500, date: DateTime(2026, 11, 1)));
    if (owner != null) {
      await legacy.db.insert(Tables.appSettings, {
        'key': SyncKeys.ownerUid,
        'value': owner,
      });
    }
    await legacy.close();
  }

  Future<List<String>> transactionIds(AppDatabase db) async => [
    for (final row in await db.db.query(Tables.transactions, columns: ['id']))
      row['id']! as String,
  ];

  Future<String?> owner(AppDatabase db) async {
    final rows = await db.db.query(
      Tables.appSettings,
      where: 'key = ?',
      whereArgs: [SyncKeys.ownerUid],
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  test('accounts get separate databases', () async {
    final a = await AppDatabase.openForAccount('uidA', factory: factory);
    await SqliteTransactionRepository(
      a,
    ).insert(tx(id: 'a1', amountMinor: 100, date: DateTime(2026, 11, 2)));
    final b = await AppDatabase.openForAccount('uidB', factory: factory);

    expect(await transactionIds(a), ['a1']);
    expect(await transactionIds(b), isEmpty);
    await a.close();
    await b.close();
  });

  test('the shared database moves to the account it was synced with', () async {
    await createLegacy(owner: 'uidA');

    // Another account signing in first must not get it.
    final b = await AppDatabase.openForAccount('uidB', factory: factory);
    expect(await transactionIds(b), isEmpty);
    await b.close();
    expect(File(legacyPath).existsSync(), isTrue);

    final a = await AppDatabase.openForAccount('uidA', factory: factory);
    expect(await transactionIds(a), ['old']);
    expect(await owner(a), 'uidA');
    await a.close();
    expect(File(legacyPath).existsSync(), isFalse);
    expect(
      File(p.join(dir.path, AppDatabase.accountFileName('uidA'))).existsSync(),
      isTrue,
    );
  });

  test('a never-synced shared database goes to the first account', () async {
    await createLegacy();

    final a = await AppDatabase.openForAccount('uidA', factory: factory);
    expect(await transactionIds(a), ['old']);
    expect(await owner(a), 'uidA');
    await a.close();

    final b = await AppDatabase.openForAccount('uidB', factory: factory);
    expect(await transactionIds(b), isEmpty);
    await b.close();
  });

  test('file names are safe for any UID', () {
    expect(AppDatabase.accountFileName('Ab12_-'), 'money_mate_Ab12_-.db');
    expect(AppDatabase.accountFileName('../x/y'), 'money_mate____x_y.db');
  });
}

import 'package:money_mate/core/database/app_database.dart';
import 'package:sqflite/sqflite.dart';

/// Key/value storage in the AppSettings table.
///
/// Used for data that belongs with the database (and its backups), such as
/// which budget alerts have already been shown. Lightweight UI preferences
/// live in SharedPreferences instead (see SettingsProvider).
abstract class AppSettingsRepository {
  Future<String?> get(String key);

  Future<Map<String, String>> getByPrefix(String prefix);

  Future<void> set(String key, String value);

  Future<void> remove(String key);
}

class SqliteAppSettingsRepository implements AppSettingsRepository {
  SqliteAppSettingsRepository(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  @override
  Future<String?> get(String key) async {
    final rows = await _db.query(
      Tables.appSettings,
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  @override
  Future<Map<String, String>> getByPrefix(String prefix) async {
    final rows = await _db.query(
      Tables.appSettings,
      where: 'key LIKE ?',
      whereArgs: ['$prefix%'],
    );
    return {for (final r in rows) r['key']! as String: r['value']! as String};
  }

  @override
  Future<void> set(String key, String value) async {
    await _db.insert(Tables.appSettings, {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> remove(String key) async {
    await _db.delete(Tables.appSettings, where: 'key = ?', whereArgs: [key]);
  }
}

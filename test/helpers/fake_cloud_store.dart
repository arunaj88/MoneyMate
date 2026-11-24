import 'package:money_mate/core/services/cloud_transaction_store.dart';
import 'package:money_mate/models/sync_models.dart';

/// In-memory stand-in for Firestore. Batches share one server timestamp
/// (like Firestore), documents can only be written, never removed, and the
/// store can be switched offline or made to lose writes.
///
/// Collections are keyed by [CloudPartition.key]: the UID for personal
/// data, `household:{id}` for a household's shared data.
class InMemoryCloudStore implements CloudTransactionStore {
  final Map<String, Map<String, CloudTransaction>> _users = {};
  final Map<String, Map<String, Map<String, Object?>>> _raw = {};
  int _serverMicros = 1000000;

  /// When true every call fails like an unreachable server.
  bool offline = false;

  /// Partition keys whose security rules refuse access (e.g. a member who
  /// was removed from the household).
  final Set<String> denied = {};

  /// IDs whose writes are silently lost (to test verification).
  final Set<String> dropWrites = {};

  int writes = 0;
  int reads = 0;

  /// Reset marker per UID, as written by the `resetPersonalData` function.
  final Map<String, DateTime> resetMarkers = {};

  /// Simulates the `resetPersonalData` function: removes every personal
  /// document of [uid] and records the reset time.
  void resetPersonal(String uid, DateTime at) {
    _users.remove(uid);
    _raw.remove(uid);
    resetMarkers[uid] = at;
  }

  /// When true, reading `users/{uid}` is refused (security rules that
  /// predate the reset marker).
  bool userDocDenied = false;

  @override
  Future<DateTime?> personalResetAt(String uid) async {
    if (offline) throw const CloudUnavailableException('offline');
    if (userDocDenied) {
      throw CloudAccessDeniedException(CloudPartition.personal(uid));
    }
    reads++;
    return resetMarkers[uid];
  }

  /// Ownership fields written by [backfillOwnership], per document ID.
  final Map<String, Map<String, Object?>> backfilled = {};

  Map<String, CloudTransaction> docs(String key) =>
      Map.unmodifiable(_users[key] ?? const {});

  /// The raw field map last written for [id] (as Firestore would store it).
  Map<String, Object?>? rawDoc(String key, String id) => _raw[key]?[id];

  /// Writes a document as if another device had uploaded it.
  void putRemote(String key, CloudTransaction record) {
    _serverMicros += 10;
    _store(key, record, _serverMicros);
  }

  void _store(String key, CloudTransaction record, int micros) {
    (_users[key] ??= {})[record.id] = record.copyWith(
      position: SyncCursor(micros, record.id),
    );
  }

  void _check(CloudPartition partition) {
    if (offline) throw const CloudUnavailableException('offline');
    if (denied.contains(partition.key)) {
      throw CloudAccessDeniedException(partition);
    }
  }

  @override
  Future<Map<String, CloudTransaction>> fetchByIds(
    CloudPartition partition,
    List<String> ids,
  ) async {
    _check(partition);
    reads++;
    final docs = _users[partition.key] ?? const {};
    return {
      for (final id in ids)
        if (docs[id] != null) id: docs[id]!,
    };
  }

  @override
  Future<void> upsertAll(
    CloudPartition partition,
    List<CloudTransaction> records,
  ) async {
    _check(partition);
    _serverMicros += 10;
    for (final r in records) {
      writes++;
      if (dropWrites.contains(r.id)) continue;
      (_raw[partition.key] ??= {})[r.id] = r.toCloudMap(partition);
      // Re-parse like a real read: the collection decides the scope.
      final stored = CloudTransaction.fromCloudMap(
        r.id,
        r.toCloudMap(partition),
        partition: partition,
      );
      _store(partition.key, stored, _serverMicros);
    }
  }

  @override
  Future<void> backfillOwnership(
    CloudPartition partition,
    List<CloudTransaction> records,
  ) async {
    _check(partition);
    _serverMicros += 10;
    for (final r in records) {
      backfilled[r.id] = CloudTransaction.ownershipFields(
        partition,
        r.transaction,
      );
      final current = _users[partition.key]?[r.id];
      if (current == null) continue;
      _store(
        partition.key,
        CloudTransaction(
          transaction: current.transaction,
          deleted: current.deleted,
          category: current.category,
        ),
        _serverMicros,
      );
    }
  }

  @override
  Future<List<CloudTransaction>> fetchChangedSince(
    CloudPartition partition,
    SyncCursor? after, {
    int limit = 300,
  }) async {
    _check(partition);
    final sorted =
        (_users[partition.key]?.values.toList() ?? <CloudTransaction>[])
            .where((d) => after == null || d.position!.isAfter(after))
            .toList()
          ..sort((a, b) => a.position!.compareTo(b.position!));
    return sorted.take(limit).toList();
  }

  @override
  Future<CloudHistoryPage> fetchHistory(
    CloudPartition partition, {
    required DateTime before,
    DateTime? start,
    Object? cursor,
    int limit = 50,
  }) async {
    _check(partition);
    final sorted =
        (_users[partition.key]?.values.toList() ?? <CloudTransaction>[])
            .where(
              (d) =>
                  d.transaction.date.isBefore(before) &&
                  (start == null || !d.transaction.date.isBefore(start)),
            )
            .toList()
          ..sort((a, b) {
            final byDate = b.transaction.date.compareTo(a.transaction.date);
            return byDate != 0 ? byDate : b.id.compareTo(a.id);
          });
    final offset = (cursor as int?) ?? 0;
    final page = sorted.skip(offset).take(limit).toList();
    return CloudHistoryPage(
      records: page,
      cursor: offset + page.length,
      hasMore: offset + page.length < sorted.length,
    );
  }
}

/// In-memory budget / category collections.
class InMemoryRecordStore implements CloudRecordStore {
  final Map<String, Map<String, CloudRecord>> _docs = {};
  bool offline = false;
  final Set<String> denied = {};

  static String _key(CloudPartition p, CloudRecordKind kind) =>
      '${p.key}/${kind.name}';

  Map<String, CloudRecord> docs(CloudPartition p, CloudRecordKind kind) =>
      Map.unmodifiable(_docs[_key(p, kind)] ?? const {});

  void putRemote(CloudPartition p, CloudRecordKind kind, CloudRecord r) {
    (_docs[_key(p, kind)] ??= {})[r.id] = r;
  }

  /// Removes every budget and category document of [partitionKey] (what
  /// the `resetPersonalData` function does for a UID).
  void removePartition(String partitionKey) =>
      _docs.removeWhere((key, _) => key.startsWith('$partitionKey/'));

  void _check(CloudPartition partition) {
    if (offline) throw const CloudUnavailableException('offline');
    if (denied.contains(partition.key)) {
      throw CloudAccessDeniedException(partition);
    }
  }

  @override
  Future<List<CloudRecord>> fetchAll(
    CloudPartition partition,
    CloudRecordKind kind,
  ) async {
    _check(partition);
    return [...?_docs[_key(partition, kind)]?.values];
  }

  @override
  Future<void> upsertAll(
    CloudPartition partition,
    CloudRecordKind kind,
    List<CloudRecord> records,
  ) async {
    _check(partition);
    for (final r in records) {
      (_docs[_key(partition, kind)] ??= {})[r.id] = CloudRecord(
        id: r.id,
        data: {
          ...r.data,
          'id': r.id,
          'updatedAt': r.updatedAtMs,
          'deleted': r.deleted,
          if (!partition.isPersonal) 'updatedBy': partition.uid,
        },
        updatedAtMs: r.updatedAtMs,
        deleted: r.deleted,
      );
    }
  }
}

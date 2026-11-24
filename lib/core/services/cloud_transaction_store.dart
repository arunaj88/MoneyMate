import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'package:money_mate/models/sync_models.dart';

/// Thrown when the cloud cannot be reached (offline, timeout, server busy).
class CloudUnavailableException implements Exception {
  const CloudUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'CloudUnavailableException: $message';
}

/// Thrown when security rules refuse access to a collection, e.g. after the
/// user was removed from a household.
class CloudAccessDeniedException implements Exception {
  const CloudAccessDeniedException(this.partition);

  final CloudPartition partition;

  @override
  String toString() => 'CloudAccessDeniedException(${partition.key})';
}

/// One page of cloud history.
class CloudHistoryPage {
  const CloudHistoryPage({
    required this.records,
    required this.cursor,
    required this.hasMore,
  });

  /// Documents in this page, newest `date` first (including deleted ones).
  final List<CloudTransaction> records;

  /// Opaque position to pass back for the next page.
  final Object? cursor;
  final bool hasMore;
}

/// Cloud side of transaction sync.
///
/// Personal records live under `users/{uid}/transactions/{transactionId}`,
/// shared ones under `households/{householdId}/transactions/{transactionId}`.
/// Documents are never hard-deleted.
abstract class CloudTransactionStore {
  /// Reads the given documents from the server (never from a cache), so
  /// the result can be used to verify uploads.
  Future<Map<String, CloudTransaction>> fetchByIds(
    CloudPartition partition,
    List<String> ids,
  );

  /// Writes all [records] atomically per batch, stamping each with the
  /// server time used by [fetchChangedSince].
  Future<void> upsertAll(
    CloudPartition partition,
    List<CloudTransaction> records,
  );

  /// Adds the v2 ownership fields to personal documents written by older
  /// app versions, without touching their content.
  Future<void> backfillOwnership(
    CloudPartition partition,
    List<CloudTransaction> records,
  );

  /// Documents written after [after] in change-feed order.
  Future<List<CloudTransaction>> fetchChangedSince(
    CloudPartition partition,
    SyncCursor? after, {
    int limit = 300,
  });

  /// When the user last reset their personal data (written by the
  /// `resetPersonalData` function), read from the server; null if never.
  Future<DateTime?> personalResetAt(String uid);

  /// Documents with `start <= date < before`, newest first.
  Future<CloudHistoryPage> fetchHistory(
    CloudPartition partition, {
    required DateTime before,
    DateTime? start,
    Object? cursor,
    int limit = 50,
  });
}

/// Cloud side of budget and category sync (small collections).
abstract class CloudRecordStore {
  /// Every document of [kind] in [partition], read from the server.
  Future<List<CloudRecord>> fetchAll(
    CloudPartition partition,
    CloudRecordKind kind,
  );

  /// Writes [records] (batched); completes once the server confirmed them.
  Future<void> upsertAll(
    CloudPartition partition,
    CloudRecordKind kind,
    List<CloudRecord> records,
  );
}

/// Firestore paths shared by both stores and the security rules.
class CloudPaths {
  CloudPaths._();

  static const users = 'users';
  static const households = 'households';
  static const transactions = 'transactions';
  static const personalBudgets = 'personalBudgets';
  static const personalCategories = 'personalCategories';
  static const householdBudgets = 'budgets';
  static const householdCategories = 'categories';
  static const members = 'members';
  static const invitations = 'invitations';
  static const memberships = 'memberships';

  static DocumentReference<Map<String, dynamic>> root(
    FirebaseFirestore firestore,
    CloudPartition partition,
  ) => partition.isPersonal
      ? firestore.collection(users).doc(partition.uid)
      : firestore.collection(households).doc(partition.householdId);

  static String recordCollection(CloudPartition p, CloudRecordKind kind) =>
      switch (kind) {
        CloudRecordKind.budgets =>
          p.isPersonal ? personalBudgets : householdBudgets,
        CloudRecordKind.categories =>
          p.isPersonal ? personalCategories : householdCategories,
      };
}

/// Converts Firestore errors into the app's cloud exceptions.
Future<T> guardFirestore<T>(
  CloudPartition partition,
  Future<T> Function() action,
) async {
  try {
    return await action();
  } on FirebaseException catch (e) {
    if (const {
      'unavailable',
      'deadline-exceeded',
      'resource-exhausted',
      'aborted',
    }.contains(e.code)) {
      throw CloudUnavailableException(e.message ?? e.code);
    }
    if (e.code == 'permission-denied') {
      throw CloudAccessDeniedException(partition);
    }
    rethrow;
  } on TimeoutException {
    throw const CloudUnavailableException('The request timed out.');
  }
}

/// [CloudTransactionStore] backed by Cloud Firestore.
///
/// Firestore's own offline cache is disabled for this app (SQLite is the
/// offline store), so every read here comes from the server.
class FirestoreTransactionStore implements CloudTransactionStore {
  FirestoreTransactionStore({FirebaseFirestore? firestore, Duration? timeout})
    : _firestore = firestore ?? FirebaseFirestore.instance,
      _timeout = timeout ?? const Duration(seconds: 30);

  final FirebaseFirestore _firestore;
  final Duration _timeout;

  static const _serverField = 'serverUpdatedAt';
  static const _serverOnly = GetOptions(source: Source.server);

  /// Firestore allows 500 writes per batch; leave headroom.
  static const _batchSize = 400;

  /// Firestore `whereIn` accepts at most 30 values.
  static const _inLimit = 30;

  CollectionReference<Map<String, dynamic>> _collection(CloudPartition p) =>
      CloudPaths.root(_firestore, p).collection(CloudPaths.transactions);

  @override
  Future<DateTime?> personalResetAt(String uid) =>
      guardFirestore(CloudPartition.personal(uid), () async {
        final doc = await _firestore
            .collection(CloudPaths.users)
            .doc(uid)
            .get(_serverOnly)
            .timeout(_timeout);
        final ms = doc.data()?['personalResetAt'];
        return ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
      });

  @override
  Future<Map<String, CloudTransaction>> fetchByIds(
    CloudPartition partition,
    List<String> ids,
  ) => guardFirestore(partition, () async {
    final result = <String, CloudTransaction>{};
    final unique = ids.toSet().toList();
    for (var i = 0; i < unique.length; i += _inLimit) {
      final chunk = unique.sublist(i, (i + _inLimit).clamp(0, unique.length));
      final snap = await _collection(partition)
          .where(FieldPath.documentId, whereIn: chunk)
          .get(_serverOnly)
          .timeout(_timeout);
      for (final doc in snap.docs) {
        final record = _parse(partition, doc);
        if (record != null) result[record.id] = record;
      }
    }
    return result;
  });

  @override
  Future<void> upsertAll(
    CloudPartition partition,
    List<CloudTransaction> records,
  ) => guardFirestore(partition, () async {
    for (var i = 0; i < records.length; i += _batchSize) {
      final batch = _firestore.batch();
      for (final r in records.skip(i).take(_batchSize)) {
        batch.set(_collection(partition).doc(r.id), {
          ...r.toCloudMap(partition),
          _serverField: FieldValue.serverTimestamp(),
        });
      }
      await batch.commit().timeout(_timeout);
    }
  });

  @override
  Future<void> backfillOwnership(
    CloudPartition partition,
    List<CloudTransaction> records,
  ) => guardFirestore(partition, () async {
    for (var i = 0; i < records.length; i += _batchSize) {
      final batch = _firestore.batch();
      for (final r in records.skip(i).take(_batchSize)) {
        // Merge: only the ownership fields are added, content is unchanged.
        batch.set(_collection(partition).doc(r.id), {
          'schemaVersion': CloudTransaction.schemaVersion,
          ...CloudTransaction.ownershipFields(partition, r.transaction),
          'deletedAt': r.deleted ? r.updatedAtMs : null,
          _serverField: FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
      await batch.commit().timeout(_timeout);
    }
  });

  @override
  Future<List<CloudTransaction>> fetchChangedSince(
    CloudPartition partition,
    SyncCursor? after, {
    int limit = 300,
  }) => guardFirestore(partition, () async {
    Query<Map<String, dynamic>> query = _collection(
      partition,
    ).orderBy(_serverField).orderBy(FieldPath.documentId);
    if (after != null) {
      query = query.startAfter([
        Timestamp.fromMicrosecondsSinceEpoch(after.serverMicros),
        after.docId,
      ]);
    }
    final snap = await query.limit(limit).get(_serverOnly).timeout(_timeout);
    return [
      for (final doc in snap.docs)
        if (_parse(partition, doc) case final record?) record,
    ];
  });

  @override
  Future<CloudHistoryPage> fetchHistory(
    CloudPartition partition, {
    required DateTime before,
    DateTime? start,
    Object? cursor,
    int limit = 50,
  }) => guardFirestore(partition, () async {
    Query<Map<String, dynamic>> query = _collection(partition)
        .where('date', isLessThan: before.millisecondsSinceEpoch)
        .orderBy('date', descending: true);
    if (start != null) {
      query = query.where(
        'date',
        isGreaterThanOrEqualTo: start.millisecondsSinceEpoch,
      );
    }
    if (cursor is DocumentSnapshot) {
      query = query.startAfterDocument(cursor);
    }
    final snap = await query.limit(limit).get(_serverOnly).timeout(_timeout);
    return CloudHistoryPage(
      records: [
        for (final doc in snap.docs)
          if (_parse(partition, doc) case final record?) record,
      ],
      cursor: snap.docs.isEmpty ? cursor : snap.docs.last,
      hasMore: snap.docs.length == limit,
    );
  });

  CloudTransaction? _parse(
    CloudPartition partition,
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) return null;
    final server = data[_serverField];
    try {
      return CloudTransaction.fromCloudMap(
        doc.id,
        data,
        partition: partition,
        position: server is Timestamp
            ? SyncCursor(server.microsecondsSinceEpoch, doc.id)
            : null,
      );
    } on FormatException catch (e) {
      // Skip unreadable documents rather than failing the whole sync.
      debugPrint('Skipping cloud transaction ${doc.id}: $e');
      return null;
    }
  }
}

/// [CloudRecordStore] backed by Cloud Firestore.
class FirestoreRecordStore implements CloudRecordStore {
  FirestoreRecordStore({FirebaseFirestore? firestore, Duration? timeout})
    : _firestore = firestore ?? FirebaseFirestore.instance,
      _timeout = timeout ?? const Duration(seconds: 30);

  final FirebaseFirestore _firestore;
  final Duration _timeout;

  static const _batchSize = 400;

  CollectionReference<Map<String, dynamic>> _collection(
    CloudPartition p,
    CloudRecordKind kind,
  ) => CloudPaths.root(
    _firestore,
    p,
  ).collection(CloudPaths.recordCollection(p, kind));

  @override
  Future<List<CloudRecord>> fetchAll(
    CloudPartition partition,
    CloudRecordKind kind,
  ) => guardFirestore(partition, () async {
    final snap = await _collection(
      partition,
      kind,
    ).get(const GetOptions(source: Source.server)).timeout(_timeout);
    return [
      for (final doc in snap.docs)
        if (CloudRecord.fromCloudMap(doc.id, doc.data()) case final r?) r,
    ];
  });

  @override
  Future<void> upsertAll(
    CloudPartition partition,
    CloudRecordKind kind,
    List<CloudRecord> records,
  ) => guardFirestore(partition, () async {
    for (var i = 0; i < records.length; i += _batchSize) {
      final batch = _firestore.batch();
      for (final r in records.skip(i).take(_batchSize)) {
        batch.set(_collection(partition, kind).doc(r.id), {
          ...r.data,
          'id': r.id,
          'updatedAt': r.updatedAtMs,
          'deleted': r.deleted,
          if (partition.isHousehold) 'updatedBy': partition.uid,
          'serverUpdatedAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit().timeout(_timeout);
    }
  });
}

extension on CloudPartition {
  bool get isHousehold => !isPersonal;
}

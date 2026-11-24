import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/core/services/auth_service.dart';
import 'package:money_mate/core/services/transaction_sync_service.dart';

/// Thrown when cloud history cannot be shown for the signed-in account.
class CloudHistoryUnavailableException implements Exception {
  const CloudHistoryUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'CloudHistoryUnavailableException: $message';
}

/// Source of transactions that are older than the local retention window.
abstract class TransactionHistorySource {
  /// Whether a signed-in account is available to read history for.
  bool get isAvailable;

  /// Start of the local retention window: older transactions may only be
  /// in the cloud.
  Future<DateTime> localCutoff();

  /// Loads the next page for [filter], from every data scope it includes
  /// (personal and/or the household's shared collection).
  Future<HistoryResult> loadOlder({
    required TransactionFilter filter,
    required Map<String, String> categoryNames,
    Object? cursor,
  });

  /// Every cloud transaction of [scope] dated from [start] up to the local
  /// retention cutoff that is not stored on this device, for historical
  /// reports and budget history. Results are cached until [version] (the
  /// local data version) changes. Throws `CloudUnavailableException` when
  /// offline.
  Future<OlderTransactions> olderTransactions({
    required ScopeFilter scope,
    required DateTime start,
    required Map<String, String> categoryNames,
    required int version,
  });
}

/// Cloud-only transactions before the local retention window.
class OlderTransactions {
  const OlderTransactions({required this.items, required this.cutoff});

  final List<TransactionModel> items;

  /// Local records cover everything from here on.
  final DateTime cutoff;
}

/// Paging position across several data scopes.
class _ScopedCursor {
  const _ScopedCursor(this.cursors, this.exhausted);

  final Map<DataScope, Object?> cursors;
  final Set<DataScope> exhausted;
}

/// Reads cloud history for the currently signed-in Firebase user.
class CloudHistoryLoader implements TransactionHistorySource {
  CloudHistoryLoader(this._service, this._auth);

  final TransactionSyncService _service;
  final AuthService _auth;

  /// At most this many pages (of 200) are read for one historical range.
  static const int maxHistoryPages = 50;

  Object? _olderKey;
  Future<OlderTransactions>? _older;

  @override
  bool get isAvailable => _auth.currentUser != null;

  @override
  Future<OlderTransactions> olderTransactions({
    required ScopeFilter scope,
    required DateTime start,
    required Map<String, String> categoryNames,
    required int version,
  }) async {
    final uid = _requireUid();
    final owner = await _service.ownerUid();
    if (owner != null && owner != uid) {
      throw const CloudHistoryUnavailableException(
        'This device is linked to another account.',
      );
    }
    final cutoff = await _service.retentionCutoff();
    if (!start.isBefore(cutoff)) {
      return OlderTransactions(items: const [], cutoff: cutoff);
    }
    final key = (uid, scope, start, cutoff, version);
    if (key == _olderKey && _older != null) return _older!;
    _olderKey = key;
    final future = _loadOlder(uid, scope, start, cutoff, categoryNames);
    _older = future;
    try {
      return await future;
    } catch (_) {
      // Do not cache failures (e.g. offline).
      if (identical(_older, future)) {
        _older = null;
        _olderKey = null;
      }
      rethrow;
    }
  }

  Future<OlderTransactions> _loadOlder(
    String uid,
    ScopeFilter scope,
    DateTime start,
    DateTime cutoff,
    Map<String, String> categoryNames,
  ) async {
    final items = <TransactionModel>[];
    for (final dataScope in scope.dataScopes) {
      Object? cursor;
      var pages = 0;
      var hasMore = true;
      while (hasMore && pages++ < maxHistoryPages) {
        final page = await _service.loadHistory(
          CloudPartition(uid, dataScope),
          filter: TransactionFilter(start: start, end: cutoff, scope: scope),
          categoryNames: categoryNames,
          cursor: cursor,
          pageSize: 200,
          maxPages: 1,
        );
        items.addAll(page.transactions);
        cursor = page.cursor;
        hasMore = page.hasMore;
      }
    }
    return OlderTransactions(items: items, cutoff: cutoff);
  }

  String _requireUid() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      throw const CloudHistoryUnavailableException(
        'Sign in to see older transactions.',
      );
    }
    return uid;
  }

  @override
  Future<DateTime> localCutoff() => _service.retentionCutoff();

  @override
  Future<HistoryResult> loadOlder({
    required TransactionFilter filter,
    required Map<String, String> categoryNames,
    Object? cursor,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      throw const CloudHistoryUnavailableException(
        'Sign in to see older transactions.',
      );
    }
    final owner = await _service.ownerUid();
    if (owner != null && owner != uid) {
      throw const CloudHistoryUnavailableException(
        'This device is linked to another account.',
      );
    }

    final previous = cursor is _ScopedCursor ? cursor : null;
    final cursors = <DataScope, Object?>{...?previous?.cursors};
    final exhausted = <DataScope>{...?previous?.exhausted};
    final found = <TransactionModel>[];
    var categoriesAdded = false;

    for (final scope in filter.scope.dataScopes) {
      if (exhausted.contains(scope)) continue;
      final result = await _service.loadHistory(
        CloudPartition(uid, scope),
        filter: filter,
        categoryNames: categoryNames,
        cursor: cursors[scope],
      );
      cursors[scope] = result.cursor;
      if (!result.hasMore) exhausted.add(scope);
      categoriesAdded |= result.categoriesAdded;
      found.addAll(result.transactions);
    }
    found.sort((a, b) {
      final byDate = b.date.compareTo(a.date);
      return byDate != 0 ? byDate : b.createdAt.compareTo(a.createdAt);
    });
    return HistoryResult(
      transactions: found,
      cursor: _ScopedCursor(cursors, exhausted),
      hasMore: filter.scope.dataScopes.any((s) => !exhausted.contains(s)),
      categoriesAdded: categoriesAdded,
    );
  }
}

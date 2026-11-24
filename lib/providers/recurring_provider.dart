import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/services/notification_events.dart';
import '../core/services/recurring_scheduler.dart';
import '../models/recurring_model.dart';
import '../models/transaction_model.dart';
import '../repositories/recurring_repository.dart';
import 'transaction_provider.dart';

/// Recurring transactions: creates rules and adds their due occurrences.
///
/// Due occurrences are added at start-up, when the household becomes known,
/// when the app resumes ([runDue]) and right after a rule is created. Runs
/// are serialised, and every occurrence has a stable ID, so nothing is
/// ever added twice. Without a repository the feature is unavailable.
class RecurringProvider extends ChangeNotifier {
  RecurringProvider(
    this._repository, {
    RecurringSink? sink,
    Uuid? uuid,
    DateTime Function()? clock,
  }) : _sink = sink,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now;

  final RecurringRepository? _repository;

  /// Told about occurrences added automatically (a system notification).
  final RecurringSink? _sink;
  final Uuid _uuid;
  final DateTime Function() _clock;

  TransactionProvider? _transactions;
  List<RecurringRule> _rules = const [];
  bool _hasLoaded = false;
  bool _attached = false;
  String? _householdId;
  int _seenDataVersion = -1;
  Future<void> _queue = Future.value();

  bool get isAvailable => _repository != null;
  List<RecurringRule> get rules => _rules;
  bool get hasLoaded => _hasLoaded;

  /// Called by the ProxyProvider whenever transactions change.
  void attach(TransactionProvider transactions) {
    _transactions = transactions;
    if (!isAvailable) return;
    final householdChanged = transactions.householdId != _householdId;
    _householdId = transactions.householdId;
    if (!_attached || householdChanged) {
      _attached = true;
      _seenDataVersion = transactions.dataVersion;
      // Defer: this runs during the provider tree's build phase.
      Future.microtask(runDue);
    } else if (transactions.dataVersion != _seenDataVersion) {
      // Restore, reset or a category deletion may have changed rules.
      _seenDataVersion = transactions.dataVersion;
      Future.microtask(load);
    }
  }

  Future<void> load() async {
    final repository = _repository;
    if (repository == null) return;
    try {
      _rules = List.unmodifiable(await repository.getRules());
      _hasLoaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('RecurringProvider.load failed: $e');
    }
  }

  /// Adds every occurrence that is due now. Returns how many were added.
  Future<int> runDue() => _serialised(() async {
    final repository = _repository;
    if (repository == null) return 0;
    var added = 0;
    final additions = <RecurringAddition>[];
    try {
      final now = _clock();
      for (final rule in await repository.getRules()) {
        // A shared rule only runs while the user is in its household.
        if (rule.isShared && rule.householdId != _householdId) continue;
        final due = RecurringScheduler.due(rule, now);
        if (due.isEmpty) continue;
        final count = await repository.commit(due);
        added += count;
        if (count > 0) additions.add(RecurringAddition(rule, count));
      }
    } catch (e) {
      debugPrint('Adding recurring transactions failed: $e');
    }
    await _afterRun(added);
    if (additions.isNotEmpty) unawaited(_sink?.recurringAdded(additions));
    return added;
  });

  /// Creates a rule and adds its first occurrence (on [startDate]) right
  /// away, plus any later ones already due when [startDate] is in the past.
  /// Returns how many transactions were added.
  Future<int> addRule({
    required TransactionType type,
    required int amountMinor,
    required String categoryId,
    required DateTime startDate,
    required RecurrenceFrequency frequency,
    String note = '',
    PaymentMethod paymentMethod = PaymentMethod.cash,
    TransactionScope scope = TransactionScope.personal,
    String? householdId,
    String? createdBy,
    String? createdByName,
  }) {
    final repository = _repository;
    if (repository == null) {
      throw StateError('Recurring transactions are not available');
    }
    if (amountMinor <= 0) {
      throw ArgumentError('Amount must be greater than zero');
    }
    if (categoryId.isEmpty) throw ArgumentError('Please choose a category');
    if (scope == TransactionScope.shared) {
      if (householdId == null || householdId.isEmpty) {
        throw ArgumentError(
          'Join or create a household to add shared transactions',
        );
      }
      if (createdBy == null || createdBy.isEmpty) {
        throw ArgumentError('Sign in to add shared transactions');
      }
    }
    return _serialised(() async {
      final now = _clock();
      final rule = RecurringRule(
        id: _uuid.v4(),
        type: type,
        amountMinor: amountMinor,
        categoryId: categoryId,
        frequency: frequency,
        startDate: startDate,
        note: note.trim(),
        paymentMethod: paymentMethod,
        scope: scope,
        householdId: scope == TransactionScope.shared ? householdId : null,
        createdAt: now,
        updatedAt: now,
        createdBy: createdBy,
        createdByName: createdByName,
      );
      await repository.insert(rule);
      final added = await repository.commit(RecurringScheduler.due(rule, now));
      await _afterRun(added);
      return added;
    });
  }

  /// Stops [rule] repeating; transactions it already added are kept.
  Future<void> stopRule(RecurringRule rule) => _serialised(() async {
    await _repository?.delete(rule.id);
    await load();
  });

  Future<void> _afterRun(int added) async {
    await load();
    if (added > 0) {
      final transactions = _transactions;
      if (transactions != null) {
        await transactions.reloadAfterExternalChange();
        _seenDataVersion = transactions.dataVersion;
      }
    }
  }

  Future<T> _serialised<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}

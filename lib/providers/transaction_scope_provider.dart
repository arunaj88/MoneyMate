import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/providers/household_provider.dart';

/// App-wide choice of which transactions to show: personal or the
/// household's shared ones. Without a household it is always personal.
///
/// The dashboard, transaction list and reports all follow it, so the
/// numbers on every screen describe the same set of transactions.
///
/// Every launch opens on the personal view; switching to the household
/// view lasts until the app is closed. The choice is not saved, and a
/// value saved by older versions is removed.
class TransactionScopeProvider extends ChangeNotifier {
  TransactionScopeProvider(SharedPreferences prefs) {
    if (prefs.containsKey(PrefKeys.viewScope)) {
      prefs.remove(PrefKeys.viewScope);
    }
  }

  ViewScope _view = ViewScope.personal;
  String? _householdId;
  String? _householdName;
  bool _disposed = false;

  /// The effective view (personal while the user has no household).
  ViewScope get view => _householdId == null ? ViewScope.personal : _view;

  String? get householdId => _householdId;
  String? get householdName => _householdName;

  /// Whether shared views (and shared transactions) are possible.
  bool get canShare => _householdId != null;

  ScopeFilter get filter => ScopeFilter.forView(view, _householdId);

  void updateHousehold(HouseholdProvider household) {
    final id = household.householdId;
    final name = household.household?.name;
    if (id == _householdId && name == _householdName) return;
    _householdId = id;
    _householdName = name;
    // Runs during the provider tree's build.
    Future.microtask(_notify);
  }

  Future<void> setView(ViewScope view) async {
    if (view == _view) return;
    _view = view;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

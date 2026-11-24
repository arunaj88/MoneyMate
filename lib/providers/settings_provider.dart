import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../core/constants/currencies.dart';
import '../core/utils/money.dart';

/// User preferences persisted with SharedPreferences.
class SettingsProvider extends ChangeNotifier {
  SettingsProvider(this._prefs) {
    _load();
  }

  final SharedPreferences _prefs;

  ThemeMode _themeMode = ThemeMode.system;
  String _currencyCode = Currencies.defaultCode;
  int _firstDayOfWeek = DateTime.monday;
  bool _budgetAlertsEnabled = true;
  bool _categoryAlertsEnabled = true;
  bool _recurringNotifications = true;
  bool _householdActivityNotifications = true;
  bool _householdBudgetNotifications = true;
  bool _savingsNotifications = true;
  late CurrencyFormatter _formatter = CurrencyFormatter(_currencyCode);

  ThemeMode get themeMode => _themeMode;
  String get currencyCode => _currencyCode;
  CurrencyInfo get currency => Currencies.byCode(_currencyCode);

  /// [DateTime.monday] (1) … [DateTime.sunday] (7). Defaults to Monday so a
  /// week runs Monday–Sunday.
  int get firstDayOfWeek => _firstDayOfWeek;
  bool get budgetAlertsEnabled => _budgetAlertsEnabled;
  bool get categoryAlertsEnabled => _categoryAlertsEnabled;

  /// A notification when recurring transactions are added automatically.
  bool get recurringNotifications => _recurringNotifications;

  /// Pushes when household members add, edit or delete shared
  /// transactions, or join or leave.
  bool get householdActivityNotifications => _householdActivityNotifications;

  /// Pushes when a shared budget reaches 80%, 90% or 100%.
  bool get householdBudgetNotifications => _householdBudgetNotifications;

  /// Pushes about household and shared savings goals.
  bool get savingsNotifications => _savingsNotifications;
  CurrencyFormatter get formatter => _formatter;

  void _load() {
    final theme = _prefs.getString(PrefKeys.themeMode);
    _themeMode = ThemeMode.values.firstWhere(
      (m) => m.name == theme,
      orElse: () => ThemeMode.system,
    );
    final code = _prefs.getString(PrefKeys.currencyCode);
    _currencyCode = Currencies.all.any((c) => c.code == code)
        ? code!
        : Currencies.defaultCode;
    final firstDay = _prefs.getInt(PrefKeys.firstDayOfWeek);
    _firstDayOfWeek = (firstDay != null && firstDay >= 1 && firstDay <= 7)
        ? firstDay
        : DateTime.monday;
    _budgetAlertsEnabled = _prefs.getBool(PrefKeys.budgetAlertsEnabled) ?? true;
    _categoryAlertsEnabled =
        _prefs.getBool(PrefKeys.categoryAlertsEnabled) ?? true;
    _recurringNotifications =
        _prefs.getBool(PrefKeys.recurringNotifications) ?? true;
    _householdActivityNotifications =
        _prefs.getBool(PrefKeys.householdActivityNotifications) ?? true;
    _householdBudgetNotifications =
        _prefs.getBool(PrefKeys.householdBudgetNotifications) ?? true;
    _savingsNotifications =
        _prefs.getBool(PrefKeys.savingsNotifications) ?? true;
    _formatter = CurrencyFormatter(_currencyCode);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    notifyListeners();
    await _prefs.setString(PrefKeys.themeMode, mode.name);
  }

  Future<void> setCurrency(String code) async {
    if (code == _currencyCode) return;
    _currencyCode = Currencies.byCode(code).code;
    _formatter = CurrencyFormatter(_currencyCode);
    notifyListeners();
    await _prefs.setString(PrefKeys.currencyCode, _currencyCode);
  }

  Future<void> setFirstDayOfWeek(int weekday) async {
    if (weekday < 1 || weekday > 7 || weekday == _firstDayOfWeek) return;
    _firstDayOfWeek = weekday;
    notifyListeners();
    await _prefs.setInt(PrefKeys.firstDayOfWeek, weekday);
  }

  Future<void> setBudgetAlertsEnabled(bool value) async {
    _budgetAlertsEnabled = value;
    notifyListeners();
    await _prefs.setBool(PrefKeys.budgetAlertsEnabled, value);
  }

  Future<void> setCategoryAlertsEnabled(bool value) async {
    _categoryAlertsEnabled = value;
    notifyListeners();
    await _prefs.setBool(PrefKeys.categoryAlertsEnabled, value);
  }

  Future<void> setRecurringNotifications(bool value) async {
    _recurringNotifications = value;
    notifyListeners();
    await _prefs.setBool(PrefKeys.recurringNotifications, value);
  }

  Future<void> setHouseholdActivityNotifications(bool value) async {
    _householdActivityNotifications = value;
    notifyListeners();
    await _prefs.setBool(PrefKeys.householdActivityNotifications, value);
  }

  Future<void> setHouseholdBudgetNotifications(bool value) async {
    _householdBudgetNotifications = value;
    notifyListeners();
    await _prefs.setBool(PrefKeys.householdBudgetNotifications, value);
  }

  Future<void> setSavingsNotifications(bool value) async {
    _savingsNotifications = value;
    notifyListeners();
    await _prefs.setBool(PrefKeys.savingsNotifications, value);
  }

  /// Notification switches, as stored in backups.
  static const Map<String, String> _notificationKeys = {
    'recurringNotifications': PrefKeys.recurringNotifications,
    'householdActivityNotifications': PrefKeys.householdActivityNotifications,
    'householdBudgetNotifications': PrefKeys.householdBudgetNotifications,
    'savingsNotifications': PrefKeys.savingsNotifications,
  };

  /// Snapshot of preferences for backups.
  Map<String, Object> toJson() => {
    'themeMode': _themeMode.name,
    'currencyCode': _currencyCode,
    'firstDayOfWeek': _firstDayOfWeek,
    'budgetAlertsEnabled': _budgetAlertsEnabled,
    'categoryAlertsEnabled': _categoryAlertsEnabled,
    'recurringNotifications': _recurringNotifications,
    'householdActivityNotifications': _householdActivityNotifications,
    'householdBudgetNotifications': _householdBudgetNotifications,
    'savingsNotifications': _savingsNotifications,
  };

  /// Restores every preference to its default (used by Reset App).
  Future<void> resetToDefaults() async {
    for (final key in [
      PrefKeys.themeMode,
      PrefKeys.currencyCode,
      PrefKeys.firstDayOfWeek,
      PrefKeys.budgetAlertsEnabled,
      PrefKeys.categoryAlertsEnabled,
      ..._notificationKeys.values,
    ]) {
      await _prefs.remove(key);
    }
    _load();
    notifyListeners();
  }

  /// Applies preferences from a backup, ignoring invalid values.
  Future<void> applyJson(Map<String, dynamic> json) async {
    final theme = json['themeMode'];
    if (theme is String) {
      await _prefs.setString(PrefKeys.themeMode, theme);
    }
    final code = json['currencyCode'];
    if (code is String && Currencies.all.any((c) => c.code == code)) {
      await _prefs.setString(PrefKeys.currencyCode, code);
    }
    final firstDay = json['firstDayOfWeek'];
    if (firstDay is int && firstDay >= 1 && firstDay <= 7) {
      await _prefs.setInt(PrefKeys.firstDayOfWeek, firstDay);
    }
    final budgetAlerts = json['budgetAlertsEnabled'];
    if (budgetAlerts is bool) {
      await _prefs.setBool(PrefKeys.budgetAlertsEnabled, budgetAlerts);
    }
    final categoryAlerts = json['categoryAlertsEnabled'];
    if (categoryAlerts is bool) {
      await _prefs.setBool(PrefKeys.categoryAlertsEnabled, categoryAlerts);
    }
    for (final entry in _notificationKeys.entries) {
      final value = json[entry.key];
      if (value is bool) await _prefs.setBool(entry.value, value);
    }
    _load();
    notifyListeners();
  }
}

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
  late CurrencyFormatter _formatter = CurrencyFormatter(_currencyCode);

  ThemeMode get themeMode => _themeMode;
  String get currencyCode => _currencyCode;
  CurrencyInfo get currency => Currencies.byCode(_currencyCode);

  /// [DateTime.monday] (1) … [DateTime.sunday] (7). Defaults to Monday so a
  /// week runs Monday–Sunday.
  int get firstDayOfWeek => _firstDayOfWeek;
  bool get budgetAlertsEnabled => _budgetAlertsEnabled;
  bool get categoryAlertsEnabled => _categoryAlertsEnabled;
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

  /// Snapshot of preferences for backups.
  Map<String, Object> toJson() => {
    'themeMode': _themeMode.name,
    'currencyCode': _currencyCode,
    'firstDayOfWeek': _firstDayOfWeek,
    'budgetAlertsEnabled': _budgetAlertsEnabled,
    'categoryAlertsEnabled': _categoryAlertsEnabled,
  };

  /// Restores every preference to its default (used by Reset App).
  Future<void> resetToDefaults() async {
    for (final key in [
      PrefKeys.themeMode,
      PrefKeys.currencyCode,
      PrefKeys.firstDayOfWeek,
      PrefKeys.budgetAlertsEnabled,
      PrefKeys.categoryAlertsEnabled,
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
    _load();
    notifyListeners();
  }
}

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/category_model.dart';
import '../models/transaction_model.dart';
import '../repositories/category_repository.dart';

/// Loads and manages income and expense categories.
class CategoryProvider extends ChangeNotifier {
  CategoryProvider(this._repository, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final CategoryRepository _repository;
  final Uuid _uuid;

  List<CategoryModel> _categories = const [];
  Map<String, CategoryModel> _byId = const {};
  bool _isLoading = false;
  String? _error;
  int _version = 0;

  List<CategoryModel> get categories => _categories;
  Map<String, CategoryModel> get byId => _byId;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Incremented whenever categories change; dependants use it to refresh.
  int get version => _version;

  List<CategoryModel> get expenseCategories =>
      _categories.where((c) => c.type == TransactionType.expense).toList();

  List<CategoryModel> get incomeCategories =>
      _categories.where((c) => c.type == TransactionType.income).toList();

  List<CategoryModel> forType(TransactionType type) =>
      type == TransactionType.expense ? expenseCategories : incomeCategories;

  CategoryModel? byIdOrNull(String id) => _byId[id];

  Future<void> load() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _setCategories(await _repository.getAll());
    } catch (e) {
      _error = 'Could not load categories: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void _setCategories(List<CategoryModel> list) {
    _categories = List.unmodifiable(list);
    _byId = Map.unmodifiable({for (final c in list) c.id: c});
    _version++;
  }

  /// Returns an error message, or null when [name] is acceptable.
  Future<String?> validateName(
    String name,
    TransactionType type, {
    String? excludeId,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Please enter a name';
    if (trimmed.length > 30) return 'Name must be 30 characters or fewer';
    if (await _repository.nameExists(trimmed, type, excludeId: excludeId)) {
      return 'A ${type.label.toLowerCase()} category with this name exists';
    }
    return null;
  }

  Future<CategoryModel> addCategory({
    required String name,
    required TransactionType type,
    required String iconKey,
    required int colorValue,
  }) async {
    final category = CategoryModel(
      id: _uuid.v4(),
      name: name.trim(),
      type: type,
      iconKey: iconKey,
      colorValue: colorValue,
      sortOrder: 50,
    );
    await _repository.insert(category);
    _setCategories(await _repository.getAll());
    notifyListeners();
    return category;
  }

  Future<void> updateCategory(CategoryModel category) async {
    await _repository.update(category.copyWith(name: category.name.trim()));
    _setCategories(await _repository.getAll());
    notifyListeners();
  }

  Future<void> deleteCategory(CategoryModel category) async {
    await _repository.delete(category);
    _setCategories(await _repository.getAll());
    notifyListeners();
  }
}

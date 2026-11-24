import 'package:flutter/material.dart';

import '../core/constants/category_icons.dart';
import 'transaction_model.dart';

/// A spending or income category.
class CategoryModel {
  const CategoryModel({
    required this.id,
    required this.name,
    required this.type,
    required this.iconKey,
    required this.colorValue,
    this.isDefault = false,
    this.sortOrder = 0,
  });

  final String id;
  final String name;
  final TransactionType type;
  final String iconKey;

  /// ARGB colour value.
  final int colorValue;

  /// Built-in categories cannot be deleted.
  final bool isDefault;
  final int sortOrder;

  IconData get icon => CategoryIcons.of(iconKey);
  Color get color => Color(colorValue);

  CategoryModel copyWith({
    String? name,
    String? iconKey,
    int? colorValue,
    int? sortOrder,
  }) {
    return CategoryModel(
      id: id,
      name: name ?? this.name,
      type: type,
      iconKey: iconKey ?? this.iconKey,
      colorValue: colorValue ?? this.colorValue,
      isDefault: isDefault,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'type': type.name,
    'icon_key': iconKey,
    'color_value': colorValue,
    'is_default': isDefault ? 1 : 0,
    'sort_order': sortOrder,
  };

  factory CategoryModel.fromMap(Map<String, Object?> map) {
    return CategoryModel(
      id: map['id']! as String,
      name: map['name']! as String,
      type: TransactionType.fromName(map['type']! as String),
      iconKey: (map['icon_key'] as String?) ?? CategoryIcons.fallbackKey,
      colorValue: map['color_value']! as int,
      isDefault: (map['is_default'] as int? ?? 0) == 1,
      sortOrder: map['sort_order'] as int? ?? 0,
    );
  }

  Map<String, Object?> toJson() => toMap();

  factory CategoryModel.fromJson(Map<String, dynamic> json) =>
      CategoryModel.fromMap(json);

  @override
  bool operator ==(Object other) =>
      other is CategoryModel &&
      other.id == id &&
      other.name == name &&
      other.type == type &&
      other.iconKey == iconKey &&
      other.colorValue == colorValue;

  @override
  int get hashCode => Object.hash(id, name, type, iconKey, colorValue);
}

/// Built-in categories created on first launch.
///
/// IDs are stable so backups from different devices stay compatible.
class DefaultCategories {
  DefaultCategories._();

  static const String otherExpenseId = 'exp_other';
  static const String otherIncomeId = 'inc_other';

  static const List<CategoryModel> all = [
    CategoryModel(
      id: 'exp_food',
      name: 'Food',
      type: TransactionType.expense,
      iconKey: 'food',
      colorValue: 0xFFEF6C57,
      isDefault: true,
      sortOrder: 0,
    ),
    CategoryModel(
      id: 'exp_groceries',
      name: 'Groceries',
      type: TransactionType.expense,
      iconKey: 'groceries',
      colorValue: 0xFF66BB6A,
      isDefault: true,
      sortOrder: 1,
    ),
    CategoryModel(
      id: 'exp_shopping',
      name: 'Shopping',
      type: TransactionType.expense,
      iconKey: 'shopping',
      colorValue: 0xFFAB47BC,
      isDefault: true,
      sortOrder: 2,
    ),
    CategoryModel(
      id: 'exp_transport',
      name: 'Transportation',
      type: TransactionType.expense,
      iconKey: 'transport',
      colorValue: 0xFF42A5F5,
      isDefault: true,
      sortOrder: 3,
    ),
    CategoryModel(
      id: 'exp_fuel',
      name: 'Fuel',
      type: TransactionType.expense,
      iconKey: 'fuel',
      colorValue: 0xFFFFA726,
      isDefault: true,
      sortOrder: 4,
    ),
    CategoryModel(
      id: 'exp_rent',
      name: 'Rent',
      type: TransactionType.expense,
      iconKey: 'rent',
      colorValue: 0xFF8D6E63,
      isDefault: true,
      sortOrder: 5,
    ),
    CategoryModel(
      id: 'exp_utilities',
      name: 'Utilities',
      type: TransactionType.expense,
      iconKey: 'utilities',
      colorValue: 0xFFFFCA28,
      isDefault: true,
      sortOrder: 6,
    ),
    CategoryModel(
      id: 'exp_healthcare',
      name: 'Healthcare',
      type: TransactionType.expense,
      iconKey: 'healthcare',
      colorValue: 0xFFEC407A,
      isDefault: true,
      sortOrder: 7,
    ),
    CategoryModel(
      id: 'exp_entertainment',
      name: 'Entertainment',
      type: TransactionType.expense,
      iconKey: 'entertainment',
      colorValue: 0xFF7E57C2,
      isDefault: true,
      sortOrder: 8,
    ),
    CategoryModel(
      id: 'exp_education',
      name: 'Education',
      type: TransactionType.expense,
      iconKey: 'education',
      colorValue: 0xFF26A69A,
      isDefault: true,
      sortOrder: 9,
    ),
    CategoryModel(
      id: 'exp_travel',
      name: 'Travel',
      type: TransactionType.expense,
      iconKey: 'travel',
      colorValue: 0xFF29B6F6,
      isDefault: true,
      sortOrder: 10,
    ),
    CategoryModel(
      id: otherExpenseId,
      name: 'Other',
      type: TransactionType.expense,
      iconKey: 'other',
      colorValue: 0xFF78909C,
      isDefault: true,
      sortOrder: 99,
    ),
    CategoryModel(
      id: 'inc_salary',
      name: 'Salary',
      type: TransactionType.income,
      iconKey: 'salary',
      colorValue: 0xFF2E7D32,
      isDefault: true,
      sortOrder: 0,
    ),
    CategoryModel(
      id: 'inc_freelance',
      name: 'Freelance',
      type: TransactionType.income,
      iconKey: 'freelance',
      colorValue: 0xFF00897B,
      isDefault: true,
      sortOrder: 1,
    ),
    CategoryModel(
      id: 'inc_business',
      name: 'Business',
      type: TransactionType.income,
      iconKey: 'business',
      colorValue: 0xFF5C6BC0,
      isDefault: true,
      sortOrder: 2,
    ),
    CategoryModel(
      id: 'inc_investment',
      name: 'Investment',
      type: TransactionType.income,
      iconKey: 'investment',
      colorValue: 0xFF9CCC65,
      isDefault: true,
      sortOrder: 3,
    ),
    CategoryModel(
      id: otherIncomeId,
      name: 'Other',
      type: TransactionType.income,
      iconKey: 'other',
      colorValue: 0xFF90A4AE,
      isDefault: true,
      sortOrder: 99,
    ),
  ];

  static String otherIdFor(TransactionType type) =>
      type == TransactionType.expense ? otherExpenseId : otherIncomeId;
}

import 'package:flutter/material.dart';

/// Maps stable icon keys (persisted in the database) to Material icons.
///
/// Icons are stored by key instead of code point so that release builds can
/// tree-shake the icon font and so that icons survive Flutter upgrades.
class CategoryIcons {
  CategoryIcons._();

  static const String fallbackKey = 'other';

  static const Map<String, IconData> icons = {
    'food': Icons.restaurant_rounded,
    'groceries': Icons.local_grocery_store_rounded,
    'shopping': Icons.shopping_bag_rounded,
    'transport': Icons.directions_bus_rounded,
    'fuel': Icons.local_gas_station_rounded,
    'rent': Icons.home_rounded,
    'utilities': Icons.bolt_rounded,
    'healthcare': Icons.local_hospital_rounded,
    'entertainment': Icons.movie_rounded,
    'education': Icons.school_rounded,
    'travel': Icons.flight_takeoff_rounded,
    'salary': Icons.account_balance_wallet_rounded,
    'freelance': Icons.laptop_mac_rounded,
    'business': Icons.storefront_rounded,
    'investment': Icons.trending_up_rounded,
    'gift': Icons.card_giftcard_rounded,
    'pets': Icons.pets_rounded,
    'fitness': Icons.fitness_center_rounded,
    'phone': Icons.smartphone_rounded,
    'coffee': Icons.local_cafe_rounded,
    'car': Icons.directions_car_rounded,
    'kids': Icons.child_care_rounded,
    'insurance': Icons.verified_user_rounded,
    'subscriptions': Icons.subscriptions_rounded,
    'savings': Icons.savings_rounded,
    'beauty': Icons.spa_rounded,
    'other': Icons.category_rounded,
  };

  static IconData of(String key) => icons[key] ?? icons[fallbackKey]!;
}

/// Palette available for categories.
class CategoryColors {
  CategoryColors._();

  static const List<Color> palette = [
    Color(0xFFEF6C57),
    Color(0xFF4CAF50),
    Color(0xFFAB47BC),
    Color(0xFF42A5F5),
    Color(0xFFFFA726),
    Color(0xFF8D6E63),
    Color(0xFFFFCA28),
    Color(0xFFEC407A),
    Color(0xFF7E57C2),
    Color(0xFF26A69A),
    Color(0xFF29B6F6),
    Color(0xFF78909C),
    Color(0xFF2E7D32),
    Color(0xFF00897B),
    Color(0xFF5C6BC0),
    Color(0xFF9CCC65),
  ];
}

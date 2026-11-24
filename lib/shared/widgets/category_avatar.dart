import 'package:flutter/material.dart';

import 'package:money_mate/models/category_model.dart';

/// Rounded square showing a category's icon in its colour.
class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar({super.key, required this.category, this.size = 44});

  final CategoryModel? category;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = category?.color ?? Theme.of(context).colorScheme.outline;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(size * 0.32),
      ),
      child: Icon(
        category?.icon ?? Icons.help_outline_rounded,
        color: color,
        size: size * 0.52,
      ),
    );
  }
}

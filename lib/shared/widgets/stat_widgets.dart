import 'package:flutter/material.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/shared/widgets/app_card.dart';

/// Shows a percentage change. For expenses an increase is bad (red), for
/// income an increase is good (green) – controlled by [increaseIsGood].
class ChangeBadge extends StatelessWidget {
  const ChangeBadge({
    super.key,
    required this.percent,
    this.increaseIsGood = false,
    this.suffix = '',
    this.emptyLabel = 'No earlier data',
  });

  final double? percent;
  final bool increaseIsGood;
  final String suffix;

  /// Shown when [percent] is null (nothing to compare against).
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (percent == null) {
      return Text(
        emptyLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final up = percent! > 0;
    final flat = percent!.abs() < 0.5;
    final good = flat ? null : (up == increaseIsGood);
    final color = good == null
        ? theme.colorScheme.onSurfaceVariant
        : good
        ? context.finance.income
        : context.finance.expense;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          flat
              ? Icons.trending_flat_rounded
              : up
              ? Icons.trending_up_rounded
              : Icons.trending_down_rounded,
          size: 16,
          color: color,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            '${percent!.abs().toStringAsFixed(0)}%$suffix',
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Compact card with an icon, label and value.
class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.footer,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final Widget? footer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (footer != null) ...[const SizedBox(height: Spacing.xs), footer!],
        ],
      ),
    );
  }
}

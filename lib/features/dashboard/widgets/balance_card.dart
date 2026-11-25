import 'package:flutter/material.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/money.dart';

/// Hero card with the available balance and this month's income/expenses.
class BalanceCard extends StatelessWidget {
  const BalanceCard({
    super.key,
    required this.balanceMinor,
    required this.monthIncomeMinor,
    required this.monthExpenseMinor,
    required this.formatter,
    this.title = 'Total balance',
    this.savedMinor,
    this.onSavingsTap,
    this.lentMinor,
    this.onLentTap,
  });

  /// Label above the balance (e.g. "Household balance").
  final String title;

  final int balanceMinor;
  final int monthIncomeMinor;
  final int monthExpenseMinor;
  final CurrencyFormatter formatter;

  /// Money held in savings goals, shown under the balance when not null.
  final int? savedMinor;
  final VoidCallback? onSavingsTap;

  /// Principal lent and not yet repaid, shown under the balance when not
  /// null.
  final int? lentMinor;
  final VoidCallback? onLentTap;

  @override
  Widget build(BuildContext context) {
    final finance = context.finance;
    final theme = Theme.of(context);
    const onCard = Colors.white;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: finance.balanceGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(Spacing.radius + 4),
        boxShadow: [
          BoxShadow(
            color: finance.balanceGradient.first.withValues(alpha: 0.3),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            right: -40,
            top: -40,
            child: _Circle(size: 160, opacity: 0.08),
          ),
          Positioned(
            right: 30,
            bottom: -60,
            child: _Circle(size: 120, opacity: 0.06),
          ),
          Padding(
            padding: const EdgeInsets.all(Spacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: onCard.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                    Icon(
                      Icons.account_balance_wallet_outlined,
                      color: onCard.withValues(alpha: 0.8),
                      size: 20,
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.sm),
                TweenAnimationBuilder<double>(
                  tween: Tween(end: balanceMinor.toDouble()),
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) => FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      formatter.format(value.round()),
                      key: const Key('balanceText'),
                      style: theme.textTheme.headlineLarge?.copyWith(
                        color: onCard,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                ),
                if (savedMinor != null || lentMinor != null) ...[
                  const SizedBox(height: Spacing.sm),
                  Wrap(
                    spacing: Spacing.sm,
                    runSpacing: Spacing.xs,
                    children: [
                      if (savedMinor != null)
                        _BalanceChip(
                          key: const Key('balanceSavingsChip'),
                          textKey: const Key('balanceSavedText'),
                          icon: Icons.savings_outlined,
                          text: 'In savings: ${formatter.format(savedMinor!)}',
                          onTap: onSavingsTap,
                        ),
                      if (lentMinor != null)
                        _BalanceChip(
                          key: const Key('balanceLentChip'),
                          textKey: const Key('balanceLentText'),
                          icon: Icons.handshake_outlined,
                          text: 'Lent out: ${formatter.format(lentMinor!)}',
                          onTap: onLentTap,
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: Spacing.xl),
                Row(
                  children: [
                    Expanded(
                      child: _MiniStat(
                        icon: Icons.south_west_rounded,
                        label: 'Month income',
                        value: formatter.format(monthIncomeMinor),
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 36,
                      color: onCard.withValues(alpha: 0.2),
                    ),
                    const SizedBox(width: Spacing.lg),
                    Expanded(
                      child: _MiniStat(
                        icon: Icons.north_east_rounded,
                        label: 'Month expenses',
                        value: formatter.format(monthExpenseMinor),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A tappable figure under the balance (savings, money lent).
class _BalanceChip extends StatelessWidget {
  const _BalanceChip({
    super.key,
    required this.textKey,
    required this.icon,
    required this.text,
    this.onTap,
  });

  final Key textKey;
  final IconData icon;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const onCard = Colors.white;
    return Material(
      color: Colors.white.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: onCard),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text,
                  key: textKey,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: onCard,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onTap != null)
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: onCard,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Circle extends StatelessWidget {
  const _Circle({required this.size, required this.opacity});

  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.white.withValues(alpha: opacity),
    ),
  );
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 16, color: Colors.white),
        ),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.75),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme/theme.dart';
import '../../data/models/deal.dart' show Currency;
import '../../data/models/project.dart';
import '../../widgets/common/badge.dart';
import '../invoices/invoice_format.dart';

/// Money in [currency], never the dollar sign for one this app does not list.
String projectMoneyIn(String currency, double value) =>
    money(value, Currency.symbolFor(currency));

/// A project's money, in its own currency.
String projectMoney(Project p, double value) =>
    projectMoneyIn(p.currency, value);

String shortDate(DateTime d) => DateFormat('d MMM yyyy').format(d);

class ProjectStatusPill extends StatelessWidget {
  const ProjectStatusPill({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) =>
      StatusBadge(label: project.statusLabel, color: project.statusColor);
}

/// One budget's burn: what is used against what was budgeted, and a bar
/// that turns amber at 80% and red at 100%, where the notifications fire.
class BurnBar extends StatelessWidget {
  const BurnBar({
    super.key,
    required this.label,
    required this.used,
    required this.percent,
  });

  final String label;

  /// "32h of 40h", "$4,000.00 of $10,000.00".
  final String used;
  final int? percent;

  @override
  Widget build(BuildContext context) {
    final color = burnColor(percent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Wrap, not Row: label, figures and percent overflow a Row at 390px
        // with the system font scaled up.
        Wrap(
          spacing: 8,
          runSpacing: 2,
          children: [
            Text(
              label,
              style: AppTypography.caption.copyWith(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(used, style: AppTypography.caption),
            if (percent != null)
              Text(
                '$percent%',
                style: AppTypography.caption.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: burnFraction(percent),
            minHeight: 6,
            backgroundColor: AppColors.gray200,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }
}

/// The burn bars a project has budgets for; nothing without either.
List<Widget> burnBars(Project p) {
  final hours = p.budgetHoursValue;
  final amount = p.budgetAmountValue;
  return [
    if (hours != null)
      BurnBar(
        label: 'Hours',
        used: '${hoursLabel(p.burn.loggedHours)}h of ${hoursLabel(hours)}h',
        percent: p.burn.hoursPercent,
      ),
    if (hours != null && amount != null) const SizedBox(height: 10),
    if (amount != null)
      BurnBar(
        label: 'Amount',
        used:
            '${projectMoney(p, p.burn.billableValue)} of '
            '${projectMoney(p, amount)}',
        percent: p.burn.amountPercent,
      ),
  ];
}

/// A flat bordered card with an uppercase title, as on the deal page.
class ProjectCard extends StatelessWidget {
  const ProjectCard({
    super.key,
    required this.title,
    required this.child,
    this.action,
  });

  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppLayout.borderRadiusLg,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: AppTypography.overline.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              ?action,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// A label over a value, for the overview's facts.
class ProjectFact extends StatelessWidget {
  const ProjectFact({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;

  /// Makes the value a link, at least 44px tall.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      children: [
        Icon(icon, size: 20, color: AppColors.gray400),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: AppTypography.overline.copyWith(
                  color: AppColors.textTertiary,
                  fontSize: 10,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: AppTypography.body.copyWith(
                  color: onTap == null ? null : AppColors.primary600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    if (onTap == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: row,
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: row,
        ),
      ),
    );
  }
}

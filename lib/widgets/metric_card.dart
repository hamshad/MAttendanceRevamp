import 'package:flutter/material.dart';
import '../core/theme/app_colors.dart';

/// Stat card: icon circle + value + label, with optional trend indicator.
class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.iconColor = AppColors.primary,
    this.iconBg = AppColors.primarySubtle,
    this.trend,
    this.trendUp,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color iconColor;
  final Color iconBg;

  /// Optional trend text, e.g. "+2 this week"
  final String? trend;

  /// null = no trend arrow, true = up (green), false = down (red)
  final bool? trendUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _IconCircle(icon: icon, color: iconColor, bg: iconBg),
                if (trend != null) ...[
                  const Spacer(),
                  Icon(
                    trendUp == true ? Icons.trending_up : Icons.trending_down,
                    size: 14,
                    color: trendUp == true 
                        ? AppColors.getSuccess(Theme.of(context).brightness == Brightness.dark) 
                        : AppColors.getError(Theme.of(context).brightness == Brightness.dark),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    trend!,
                    style: TextStyle(
                      fontSize: 11,
                      color: trendUp == true 
                          ? AppColors.getSuccess(Theme.of(context).brightness == Brightness.dark) 
                          : AppColors.getError(Theme.of(context).brightness == Brightness.dark),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(label, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _IconCircle extends StatelessWidget {
  const _IconCircle({required this.icon, required this.color, required this.bg});
  final IconData icon;
  final Color color;
  final Color bg;

  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, color: color, size: 20),
      );
}

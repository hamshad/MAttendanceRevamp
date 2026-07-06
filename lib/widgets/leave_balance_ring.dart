import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../core/theme/app_colors.dart';

/// Circular donut chart for a single leave type balance.
/// Shows used/remaining as a ring with the remaining count in the center.
class LeaveBalanceRing extends StatelessWidget {
  const LeaveBalanceRing({
    super.key,
    required this.leaveType,
    required this.used,
    required this.total,
    this.color = AppColors.info,
    this.size = 88,
  });

  final String leaveType;
  final int used;
  final int total;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final remaining = total - used;
    final usedFraction = total > 0 ? used / total : 0.0;

    return SizedBox(
      width: size,
      child: Column(
        children: [
          SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                PieChart(
                  PieChartData(
                    startDegreeOffset: -90,
                    sectionsSpace: 0,
                    centerSpaceRadius: size * 0.32,
                    sections: [
                      PieChartSectionData(
                        value: usedFraction,
                        color: color.withAlpha(80),
                        radius: size * 0.18,
                        showTitle: false,
                      ),
                      PieChartSectionData(
                        value: 1 - usedFraction,
                        color: color,
                        radius: size * 0.18,
                        showTitle: false,
                      ),
                    ],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$remaining',
                      style: TextStyle(
                        fontSize: size * 0.22,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                    Text(
                      'left',
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            leaveType,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';

class QuickStats extends StatelessWidget {
  final int present;
  final int absent;
  final int late;
  final int leave;

  const QuickStats({
    super.key,
    required this.present,
    required this.absent,
    required this.late,
    required this.leave,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        _StatBox(label: 'Present', value: present, color: AppColors.statusColor('Present', isDark: isDark)),
        const SizedBox(width: 8),
        _StatBox(label: 'Absent', value: absent, color: AppColors.statusColor('Absent', isDark: isDark)),
        const SizedBox(width: 8),
        _StatBox(label: 'Late', value: late, color: AppColors.statusColor('Late', isDark: isDark)),
        const SizedBox(width: 8),
        _StatBox(label: 'Leave', value: leave, color: AppColors.statusColor('Holiday', isDark: isDark)),
      ],
    );
  }
}

class _StatBox extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _StatBox({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withAlpha(18),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withAlpha(50)),
        ),
        child: Column(
          children: [
            Text(
              '$value',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

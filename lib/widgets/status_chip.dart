import 'package:flutter/material.dart';
import '../core/theme/app_colors.dart';

/// A small colored dot + label chip used for attendance/approval statuses.
/// Usage:
///   StatusChip(status: 'Present')
///   StatusChip(status: 'Pending', type: StatusChipType.approval)
enum StatusChipType { attendance, approval }

class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.status,
    this.type = StatusChipType.attendance,
    this.fontSize = 11,
  });

  final String status;
  final StatusChipType type;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = type == StatusChipType.approval
        ? AppColors.approvalColor(status, isDark: isDark)
        : AppColors.statusColor(status, isDark: isDark);
    final bg = type == StatusChipType.approval
        ? AppColors.approvalSubtleColor(status, isDark: isDark)
        : AppColors.statusSubtleColor(status, isDark: isDark);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            status,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w500,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

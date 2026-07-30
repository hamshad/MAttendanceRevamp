import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../models/attendance.dart';

class StatusCard extends StatelessWidget {
  final EmployeeStatus status;

  const StatusCard({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final color = _statusColor(status.status, isDark);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withAlpha(60)),
      ),
      color: color.withAlpha(15),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  _statusLabel(status),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
                const Spacer(),
                if (status.isLateIn && status.lateByMinutes != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange.withAlpha(30),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _formatLateDuration(status.lateByMinutes!),
                      style: const TextStyle(color: Colors.orange, fontSize: 12),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _InfoChip(
                  icon: Icons.login,
                  label: status.firstInTime != null
                      ? _time(status.firstInTime!)
                      : '--:--',
                  tooltip: 'First punch-in',
                ),
                const SizedBox(width: 12),
                _InfoChip(
                  icon: Icons.logout,
                  label: status.lastOutTime != null
                      ? _time(status.lastOutTime!)
                      : '--:--',
                  tooltip: 'Last punch-out',
                ),
                const SizedBox(width: 12),
                _InfoChip(
                  icon: Icons.timer_outlined,
                  label: status.workDuration,
                  tooltip: 'Working time',
                ),
              ],
            ),
            if (status.currentShift != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.schedule, size: 14, color: isDark ? Colors.white70 : Colors.black54),
                  const SizedBox(width: 4),
                  Text(
                    status.currentShift!,
                    style: theme.textTheme.bodySmall?.copyWith(color: isDark ? Colors.white70 : Colors.black54),
                  ),
                  if (status.officeName != null) ...[
                    const SizedBox(width: 12),
                    Icon(Icons.location_on_outlined, size: 14, color: isDark ? Colors.white70 : Colors.black54),
                    const SizedBox(width: 4),
                    Text(
                      status.officeName!,
                      style: theme.textTheme.bodySmall?.copyWith(color: isDark ? Colors.white70 : Colors.black54),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatLateDuration(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return 'Late by ${m}m';
    if (m == 0) return 'Late by ${h}h';
    return 'Late by ${h}h ${m}m';
  }

  String _time(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm';
  }

  String _statusLabel(EmployeeStatus s) {
    if (s.isOnBreak) return 'On Break';
    if (s.isPunchedIn) return 'Punched In';
    if (s.isPunchedOut) return 'Punched Out';
    if (s.hasNotPunchedIn) return 'Not Punched In';
    return s.status;
  }

  Color _statusColor(String status, bool isDark) {
    return AppColors.statusColor(status, isDark: isDark);
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;

  const _InfoChip({required this.icon, required this.label, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: isDark ? Colors.white70 : Colors.black54),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}

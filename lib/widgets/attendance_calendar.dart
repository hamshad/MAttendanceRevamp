import 'package:flutter/material.dart';
import '../core/theme/app_colors.dart';

/// Monthly attendance calendar grid (7 columns × up to 6 rows).
/// Each cell shows date + hours with status color background.
class AttendanceCalendar extends StatelessWidget {
  const AttendanceCalendar({
    super.key,
    required this.year,
    required this.month,
    required this.days,
    this.onDayTap,
    this.selectedDay,
  });

  final int year;
  final int month;
  final List<CalendarDay> days;
  final void Function(CalendarDay day)? onDayTap;
  final int? selectedDay;

  static const _weekHeaders = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Week-day headers
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: _weekHeaders
                .map((h) => Expanded(
                      child: Center(
                        child: Text(
                          h,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ))
                .toList(),
          ),
        ),
        // Grid
        _buildGrid(),
      ],
    );
  }

  Widget _buildGrid() {
    final firstDay = DateTime(year, month, 1);
    // Monday = 0 offset
    final startOffset = (firstDay.weekday - 1) % 7;
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final totalCells = startOffset + daysInMonth;
    final rows = (totalCells / 7).ceil();
    final today = DateTime.now();

    return Column(
      children: List.generate(rows, (row) {
        return Row(
          children: List.generate(7, (col) {
            final cellIndex = row * 7 + col;
            final dayNumber = cellIndex - startOffset + 1;

            if (dayNumber < 1 || dayNumber > daysInMonth) {
              return const Expanded(child: SizedBox(height: 72));
            }

            final CalendarDay? data =
                days.where((d) => d.day == dayNumber).firstOrNull;
            final isToday = today.year == year &&
                today.month == month &&
                today.day == dayNumber;
            final isSelected = selectedDay == dayNumber;

            return Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: data != null ? () => onDayTap?.call(data) : null,
                child: _DayCell(
                  dayNumber: dayNumber,
                  data: data,
                  isToday: isToday,
                  isSelected: isSelected,
                ),
              ),
            );
          }),
        );
      }),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.dayNumber,
    this.data,
    required this.isToday,
    required this.isSelected,
  });

  final int dayNumber;
  final CalendarDay? data;
  final bool isToday;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final status = data?.status ?? '';
    
    final String s = status.toLowerCase();
    Color cellBgColor = Colors.transparent;
    Color dayNumberColor = isDark ? Colors.white : AppColors.textPrimary;
    String? subLabel;
    Color subLabelColor = Colors.grey;

    if (s == 'present') {
      cellBgColor = isDark ? const Color(0xFF0E2E2A) : const Color(0xFFE6F4EA);
      dayNumberColor = isDark ? Colors.white : AppColors.textPrimary;
      subLabel = data?.hours;
      subLabelColor = isDark ? const Color(0xFF00C49F) : AppColors.success;
    } else if (s == 'halfday') {
      cellBgColor = isDark ? const Color(0xFF2A1C16) : const Color(0xFFFFF3E0);
      dayNumberColor = isDark ? Colors.white : AppColors.textPrimary;
      subLabel = data?.hours;
      subLabelColor = isDark ? const Color(0xFFE28743) : AppColors.orange;
    } else if (s == 'weekoff' || s == 'weekend') {
      cellBgColor = isDark ? const Color(0xFF1A2234) : const Color(0xFFF1F5F9);
      dayNumberColor = isDark ? Colors.white : AppColors.textPrimary;
      subLabel = 'We';
      subLabelColor = isDark ? const Color(0xFF8A99AD) : AppColors.textSecondary;
    } else if (s == 'leave') {
      cellBgColor = isDark ? const Color(0xFF2E220F) : const Color(0xFFFEF3C7);
      dayNumberColor = isDark ? Colors.white : AppColors.textPrimary;
      subLabel = 'Leave';
      subLabelColor = isDark ? const Color(0xFFF59E0B) : AppColors.warning;
    } else if (s == 'absent') {
      cellBgColor = isDark ? const Color(0xFF2E0E0E) : const Color(0xFFFEE2E2);
      dayNumberColor = isDark ? Colors.white : AppColors.textPrimary;
      subLabel = 'Ab';
      subLabelColor = isDark ? const Color(0xFFEF4444) : AppColors.error;
    } else if (s == 'wfh') {
      cellBgColor = isDark ? const Color(0xFF0E1E2E) : const Color(0xFFE8F0FE);
      dayNumberColor = isDark ? Colors.white : AppColors.textPrimary;
      subLabel = data?.hours ?? 'WFH';
      subLabelColor = isDark ? const Color(0xFF3B82F6) : AppColors.info;
    } else if (s.isNotEmpty) {
      cellBgColor = isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
      dayNumberColor = isDark ? Colors.white : AppColors.textPrimary;
      subLabel = status;
      subLabelColor = isDark ? Colors.grey.shade400 : AppColors.textSecondary;
    }

    Border? border;
    if (isSelected) {
      border = Border.all(color: const Color(0xFFFF8A00), width: 2);
    } else if (isToday) {
      border = Border.all(color: theme.colorScheme.primary, width: 2);
    }

    return Container(
      height: 72,
      margin: const EdgeInsets.all(3),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: cellBgColor,
        borderRadius: BorderRadius.circular(12),
        border: border,
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$dayNumber',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: dayNumberColor,
                ),
              ),
              if (subLabel != null && subLabel.isNotEmpty)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Text(
                    subLabel,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: subLabelColor,
                    ),
                  ),
                ),
            ],
          ),
          if (isSelected)
            Positioned(
              top: 0,
              right: 0,
              child: Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFFFF8A00),
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class CalendarDay {
  const CalendarDay({
    required this.day,
    required this.status,
    this.hours,
    this.punchIn,
    this.punchOut,
  });

  final int day;
  final String status;
  final String? hours;
  final String? punchIn;
  final String? punchOut;
}

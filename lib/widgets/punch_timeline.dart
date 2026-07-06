import 'package:flutter/material.dart';
import '../core/theme/app_colors.dart';

/// A horizontal punch timeline strip showing in/out/break markers with times.
/// Renders a scaled line from the earliest to latest punch, with labeled dots.
class PunchTimeline extends StatelessWidget {
  const PunchTimeline({super.key, required this.events});

  /// List of timeline events in chronological order.
  final List<PunchEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SizedBox(
      height: 56,
      child: Row(
        children: [
          for (int i = 0; i < events.length; i++) ...[
            _Dot(event: events[i], isDark: isDark),
            if (i < events.length - 1)
              Expanded(child: _Line(color: _lineColor(events[i].type, isDark))),
          ],
        ],
      ),
    );
  }

  Color _lineColor(PunchEventType type, bool isDark) => switch (type) {
        PunchEventType.breakStart => AppColors.warningSubtle,
        PunchEventType.breakEnd   => AppColors.warningSubtle,
        _                         => AppColors.statusColor('Present', isDark: isDark),
      };
}

class _Dot extends StatelessWidget {
  const _Dot({required this.event, required this.isDark});
  final PunchEvent event;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final color = switch (event.type) {
      PunchEventType.punchIn    => AppColors.statusColor('Present', isDark: isDark),
      PunchEventType.punchOut   => AppColors.statusColor('Absent', isDark: isDark),
      PunchEventType.breakStart => AppColors.statusColor('Late', isDark: isDark),
      PunchEventType.breakEnd   => AppColors.statusColor('Late', isDark: isDark),
    };

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: color.withAlpha(60), width: 3),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          event.time,
          style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        height: 2,
        margin: const EdgeInsets.only(bottom: 14),
        color: color.withAlpha(80),
      );
}

enum PunchEventType { punchIn, punchOut, breakStart, breakEnd }

class PunchEvent {
  const PunchEvent({required this.time, required this.type, this.label});
  final String time;
  final PunchEventType type;
  final String? label;
}

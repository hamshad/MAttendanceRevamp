import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../alignment_models.dart';

/// Persistent list of active alignment alerts on the home screen.
/// Critical alerts stay until the problem is fixed; warnings can be
/// dismissed for the session (they reappear on next app open).
class AlignmentBanner extends StatelessWidget {
  final List<AlignmentAlert> alerts;
  final ValueChanged<String>? onDismiss;

  const AlignmentBanner({super.key, required this.alerts, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    if (alerts.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final alert in alerts) _AlertCard(alert: alert, onDismiss: onDismiss),
      ],
    );
  }
}

class _AlertCard extends StatelessWidget {
  final AlignmentAlert alert;
  final ValueChanged<String>? onDismiss;

  const _AlertCard({required this.alert, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final dismissible =
        alert.severity == AlignmentSeverity.warning && onDismiss != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
        decoration: BoxDecoration(
          color: alert.subtleColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: alert.color.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 4),
              child: Icon(alert.icon, color: alert.color, size: 20),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    alert.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    alert.message,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (alert.fix != AlignmentFix.none) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: alert.runFix,
                        style: TextButton.styleFrom(
                          foregroundColor: alert.color,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                        ),
                        icon: const Icon(Icons.settings, size: 16),
                        label: Text(
                          alert.fixLabel ?? 'Fix it',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (dismissible)
              GestureDetector(
                onTap: () => onDismiss?.call(alert.id),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.close,
                    size: 18,
                    color: AppColors.textDisabled,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

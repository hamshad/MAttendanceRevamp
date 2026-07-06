import 'package:flutter/material.dart';
import '../core/theme/app_colors.dart';
import 'status_chip.dart';

/// A card showing a pending approval item (leave/regularization) with inline Approve/Reject buttons.
class PendingActionCard extends StatelessWidget {
  const PendingActionCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.status,
    this.onApprove,
    this.onReject,
    this.isLoading = false,
    this.chipType = StatusChipType.approval,
  });

  final String title;
  final String subtitle;
  final String status;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final bool isLoading;
  final StatusChipType chipType;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showActions = onApprove != null || onReject != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(subtitle, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                StatusChip(status: status, type: chipType),
              ],
            ),
            if (showActions) ...[
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (onApprove != null)
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: isLoading ? null : onApprove,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.successSubtle,
                          foregroundColor: AppColors.success,
                          minimumSize:     const Size(0, 36),
                          textStyle:       const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        child: isLoading
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Approve'),
                      ),
                    ),
                  if (onApprove != null && onReject != null) const SizedBox(width: 8),
                  if (onReject != null)
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: isLoading ? null : onReject,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.errorSubtle,
                          foregroundColor: AppColors.error,
                          minimumSize:     const Size(0, 36),
                          textStyle:       const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        child: const Text('Reject'),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

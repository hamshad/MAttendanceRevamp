import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../alignment_models.dart';

/// In-app popup for critical alignment alerts (GPS off, permission revoked).
/// Shown over the current screen via the global navigator key — the employee
/// sees the problem + a one-tap fix without hunting through settings.
Future<void> showAlignmentDialog(BuildContext context, AlignmentAlert alert) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: alert.subtleColor,
            shape: BoxShape.circle,
          ),
          child: Icon(alert.icon, color: alert.color, size: 30),
        ),
        title: Text(
          alert.title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Text(
          alert.message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary, height: 1.4),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Later'),
          ),
          if (alert.fix != AlignmentFix.none)
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                alert.runFix();
              },
              style: FilledButton.styleFrom(backgroundColor: alert.color),
              child: Text(alert.fixLabel ?? 'Fix it'),
            ),
        ],
      );
    },
  );
}

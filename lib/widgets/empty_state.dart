import 'package:flutter/material.dart';
import '../core/theme/app_colors.dart';

/// Centered empty state: icon + title + subtitle + optional CTA button.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.ctaLabel,
    this.onCta,
    this.iconColor = AppColors.gray,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? ctaLabel;
  final VoidCallback? onCta;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.graySubtle,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(icon, size: 40, color: iconColor),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
            if (ctaLabel != null && onCta != null) ...[
              const SizedBox(height: 24),
              SizedBox(
                width: 180,
                child: ElevatedButton(
                  onPressed: onCta,
                  child: Text(ctaLabel!),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

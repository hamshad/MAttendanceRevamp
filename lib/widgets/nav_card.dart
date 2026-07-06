import 'package:flutter/material.dart';
import '../core/theme/app_colors.dart';

/// Navigation item card used on the History Hub screen.
/// Icon in a colored circle + title + subtitle + right chevron.
class NavCard extends StatelessWidget {
  const NavCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.iconColor = AppColors.primary,
    this.iconBg = AppColors.primarySubtle,
    this.badge,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color iconColor;
  final Color iconBg;
  final String? badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color:        iconBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(title, style: theme.textTheme.titleMedium),
                        if (badge != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.getError(Theme.of(context).brightness == Brightness.dark),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              badge!,
                              style: const TextStyle(
                                color:      Colors.white,
                                fontSize:   10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.gray, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

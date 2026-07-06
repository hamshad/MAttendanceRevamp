import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../providers/notifications_provider.dart';

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState
    extends ConsumerState<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    // Refresh list whenever screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(notificationsProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final listAsync = ref.watch(notificationsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        leading: const BackButton(),
        actions: [
          TextButton(
            onPressed: () =>
                ref.read(notificationsProvider.notifier).markAllRead(),
            child: const Text('Mark all read'),
          ),
        ],
      ),
      body: listAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) =>
            const Center(child: Text('Could not load notifications.')),
        data: (notifications) {
          if (notifications.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.notifications_none_outlined,
                      size: 48, color: AppColors.gray),
                  const SizedBox(height: 12),
                  const Text(
                    'No notifications yet.',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 14),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () =>
                ref.read(notificationsProvider.notifier).refresh(),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: notifications.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) =>
                  _NotificationTile(notification: notifications[i]),
            ),
          );
        },
      ),
    );
  }
}

// ── Tile ──────────────────────────────────────────────────────────────────────

class _NotificationTile extends ConsumerWidget {
  final AppNotification notification;
  const _NotificationTile({required this.notification});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = notification;
    final theme = Theme.of(context);

    return InkWell(
      onTap: () {
        if (!n.isRead) {
          ref.read(notificationsProvider.notifier).markRead(n.id);
        }
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => _NotificationDetailScreen(notification: n),
          ),
        );
      },
      child: Container(
        color: n.isRead ? null : theme.colorScheme.primary.withAlpha(10),
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Unread dot
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 10),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: n.isRead
                      ? Colors.transparent
                      : theme.colorScheme.primary,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          n.title,
                          style: TextStyle(
                            fontWeight: n.isRead
                                ? FontWeight.normal
                                : FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      Text(
                        _timeAgo(n.createdAt),
                        style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.gray),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    n.body,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (n.category.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _CategoryChip(category: n.category),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec'
    ];
    final local = dt.toLocal();
    return '${months[local.month - 1]} ${local.day}';
  }
}

// ── Detail Screen ──────────────────────────────────────────────────────────────

class _NotificationDetailScreen extends StatelessWidget {
  final AppNotification notification;
  const _NotificationDetailScreen({required this.notification});

  @override
  Widget build(BuildContext context) {
    final n = notification;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Notification'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (n.imageUrl != null && n.imageUrl!.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  n.imageUrl!,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, e, s) => const SizedBox.shrink(),
                ),
              ),
              const SizedBox(height: 20),
            ],
            if (n.category.isNotEmpty) ...[
              _CategoryChip(category: n.category),
              const SizedBox(height: 12),
            ],
            Text(
              n.title,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              n.body,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.textSecondary,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _formatDate(n.createdAt),
              style: const TextStyle(fontSize: 12, color: AppColors.gray),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final period = local.hour < 12 ? 'AM' : 'PM';
    final min = local.minute.toString().padLeft(2, '0');
    return '${months[local.month - 1]} ${local.day}, ${local.year} • $hour:$min $period';
  }
}

// ── Category Chip ──────────────────────────────────────────────────────────────

class _CategoryChip extends StatelessWidget {
  final String category;
  const _CategoryChip({required this.category});

  @override
  Widget build(BuildContext context) {
    final color = _categoryColor(category);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Text(
        category,
        style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w500),
      ),
    );
  }

  Color _categoryColor(String c) {
    final lower = c.toLowerCase();
    if (lower.contains('leave')) return AppColors.info;
    if (lower.contains('payroll') || lower.contains('pay')) {
      return AppColors.success;
    }
    if (lower.contains('alert') || lower.contains('anomal')) {
      return AppColors.error;
    }
    return AppColors.gray;
  }
}

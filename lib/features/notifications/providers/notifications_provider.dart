import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/utils/date_time_utils.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

class AppNotification {
  final int id;
  final String title;
  final String body;
  final String category;
  final DateTime createdAt;
  final bool isRead;
  final String? imageUrl;

  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.category,
    required this.createdAt,
    required this.isRead,
    this.imageUrl,
  });

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as int,
        title: j['title'] as String,
        body: j['body'] as String,
        category: j['category'] as String? ?? '',
        createdAt: parseUtc(j['createdAt'] as String),
        isRead: j['isRead'] as bool? ?? false,
        imageUrl: j['imageUrl'] as String?,
      );

  AppNotification copyAsRead() => AppNotification(
        id: id,
        title: title,
        body: body,
        category: category,
        createdAt: createdAt,
        isRead: true,
        imageUrl: imageUrl,
      );
}

// ── Unread count (badge) ──────────────────────────────────────────────────────

final unreadNotificationsCountProvider = StateProvider<int>((ref) => 0);

// ── Notifications list ────────────────────────────────────────────────────────

final notificationsProvider =
    AsyncNotifierProvider<NotificationsNotifier, List<AppNotification>>(
  () => NotificationsNotifier(),
);

class NotificationsNotifier extends AsyncNotifier<List<AppNotification>> {
  @override
  Future<List<AppNotification>> build() => _fetch();

  Future<List<AppNotification>> _fetch() async {
    try {
      final dio = ref.read(dioClientProvider).dio;
      final response = await dio.get(
        ApiEndpoints.notifications,
        queryParameters: {'page': 1, 'pageSize': 50},
      );
      final wrapper = response.data['data'] as Map<String, dynamic>?;
      final items = wrapper?['items'] as List<dynamic>? ?? [];
      final notifications = items
          .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
          .toList();

      // Sync badge count
      final unread = notifications.where((n) => !n.isRead).length;
      ref.read(unreadNotificationsCountProvider.notifier).state = unread;

      return notifications;
    } catch (_) {
      return [];
    }
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }

  Future<void> markRead(int id) async {
    // Optimistically update
    final current = state.value ?? [];
    state = AsyncData(current
        .map((n) => n.id == id ? n.copyAsRead() : n)
        .toList());

    // Sync badge
    final unread =
        (state.value ?? []).where((n) => !n.isRead).length;
    ref.read(unreadNotificationsCountProvider.notifier).state = unread;

    try {
      final dio = ref.read(dioClientProvider).dio;
      await dio.patch(ApiEndpoints.markNotificationRead(id));
    } catch (_) {
      // Silent — optimistic update stands
    }
  }

  Future<void> markAllRead() async {
    final current = state.value ?? [];
    state = AsyncData(current.map((n) => n.copyAsRead()).toList());
    ref.read(unreadNotificationsCountProvider.notifier).state = 0;

    try {
      final dio = ref.read(dioClientProvider).dio;
      await dio.patch(ApiEndpoints.markAllNotificationsRead);
    } catch (_) {
      // Silent
    }
  }
}

// ── Unread count fetcher (for badge init on shell load) ───────────────────────

Future<void> fetchUnreadCount(dynamic ref) async {
  try {
    final dio = ref.read(dioClientProvider).dio;
    final response = await dio.get(ApiEndpoints.unreadCount);
    final data = response.data['data'] as Map<String, dynamic>?;
    final count = data?['unreadCount'] as int? ?? 0;
    ref.read(unreadNotificationsCountProvider.notifier).state = count;
  } catch (_) {
    // Silent
  }
}

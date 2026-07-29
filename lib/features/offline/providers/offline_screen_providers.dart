import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/offline_punch.dart';
import '../../../core/offline/offline_providers.dart';

final lastOfflinePunchTimeProvider = StateProvider<DateTime?>((ref) => null);

final offlineCooldownProvider = Provider<Duration?>((ref) {
  final last = ref.watch(lastOfflinePunchTimeProvider);
  if (last == null) return null;
  final elapsed = DateTime.now().difference(last);
  if (elapsed >= const Duration(minutes: 5)) return null;
  return const Duration(minutes: 5) - elapsed;
});

final canPunchOfflineProvider = Provider<bool>((ref) {
  final cooldown = ref.watch(offlineCooldownProvider);
  return cooldown == null;
});

final todayOfflinePunchesProvider = FutureProvider<List<OfflinePunch>>((ref) {
  ref.watch(pendingOfflineCountProvider);
  return ref.read(offlineQueueServiceProvider).getTodayPunches();
});

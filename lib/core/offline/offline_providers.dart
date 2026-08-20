import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/offline_punch.dart';
import '../auth/auth_provider.dart';
import 'connectivity_monitor.dart';
import 'offline_queue.dart';
import 'sync_service.dart';

final offlineQueueServiceProvider = Provider<OfflineQueueService>(
  (_) => OfflineQueueService(),
);

final connectivityMonitorProvider = Provider<ConnectivityMonitor>(
  (_) => ConnectivityMonitor(),
);

final syncServiceProvider = Provider<SyncService>((ref) {
  final dioClient = ref.read(dioClientProvider);
  final queue = ref.read(offlineQueueServiceProvider);
  return SyncService(dioClient, queue);
});

/// Reactive online/offline stream from connectivity_plus
final isOnlineProvider = StreamProvider<bool>((ref) {
  return ref.watch(connectivityMonitorProvider).onlineStream;
});

/// Pending offline punch count — updated after each enqueue / sync
final pendingOfflineCountProvider = StateProvider<int>((ref) {
  return ref.read(offlineQueueServiceProvider).pendingCount;
});

/// Reactive list of all offline punches — re-fetches when count changes
final offlinePunchListProvider = FutureProvider<List<OfflinePunch>>((ref) {
  ref.watch(pendingOfflineCountProvider);
  return ref.read(offlineQueueServiceProvider).getAll();
});

import 'package:hive_flutter/hive_flutter.dart';
import '../../models/offline_punch.dart';
import '../utils/constants.dart';

class OfflineQueueService {
  Box<OfflinePunch> get _box => Hive.box<OfflinePunch>(AppConstants.offlinePunchBox);

  Future<void> enqueue(OfflinePunch punch) async {
    punch.createdAt = DateTime.now();
    punch.retryCount = 0;
    await _box.add(punch);
  }

  List<OfflinePunch> getPending() => _box.values
      .where((p) => p.retryCount < AppConstants.maxRetryCount)
      .toList();

  int get pendingCount => getPending().length;

  bool get hasPending => pendingCount > 0;
}

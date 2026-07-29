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

  List<OfflinePunch> getAll() => _box.values.toList();

  List<OfflinePunch> getTodayPunches() {
    final now = DateTime.now();
    return _box.values.where((p) =>
      p.createdAt.year == now.year &&
      p.createdAt.month == now.month &&
      p.createdAt.day == now.day
    ).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> deleteItem(dynamic key) async {
    await _box.delete(key);
  }

  DateTime? get lastPunchTime {
    final all = _box.values.toList();
    if (all.isEmpty) return null;
    all.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return all.first.createdAt;
  }
}

import 'package:hive_flutter/hive_flutter.dart';
import '../../models/offline_punch.dart';
import '../utils/constants.dart';

/// Persistent queue of offline punches stored in Hive.
///
/// All reads that drive sync or timeline logic must use [getPending] (sorted
/// chronologically) so the backend receives punches in the order they were
/// made — alternation (In → Out → In) only works server-side if ordering is
/// preserved.
class OfflineQueueService {
  Box<OfflinePunch> get _box => Hive.box<OfflinePunch>(AppConstants.offlinePunchBox);

  Box get _cache => Hive.box(AppConstants.cacheBox);

  static const _lastPunchTimeKey = 'offline_last_punch_time';

  Future<void> enqueue(OfflinePunch punch) async {
    punch.createdAt = DateTime.now();
    punch.retryCount = 0;
    punch.errorMessage = null;
    await _box.add(punch);
    await _cache.put(_lastPunchTimeKey, punch.createdAt.toIso8601String());
  }

  /// Pending (retryable) punches sorted oldest-first — the order the backend
  /// must receive them in.
  List<OfflinePunch> getPending() {
    final pending = _box.values
        .where((p) => p.retryCount < AppConstants.maxRetryCount)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return pending;
  }

  int get pendingCount => getPending().length;

  bool get hasPending => pendingCount > 0;

  List<OfflinePunch> getAll() {
    final all = _box.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return all;
  }

  List<OfflinePunch> getTodayPunches() {
    final now = DateTime.now();
    return _box.values.where((p) =>
      p.createdAt.year == now.year &&
      p.createdAt.month == now.month &&
      p.createdAt.day == now.day
    ).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Direction of the most recent NON-FAILED queued punch **from today**, or null.
  /// Failed punches (retryCount >= max) were never accepted by the server,
  /// so they must NOT influence timeline alternation. Scoped to today because
  /// attendance alternation (In/Out) resets each day — a stale pending punch
  /// from a previous day (e.g. queued during a network outage) must never
  /// block the next day's punch-in.
  String? get lastPendingDirection {
    final now = DateTime.now();
    final all = _box.values
        .where((p) =>
            p.retryCount < AppConstants.maxRetryCount &&
            p.createdAt.year == now.year &&
            p.createdAt.month == now.month &&
            p.createdAt.day == now.day)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return all.isEmpty ? null : all.first.direction;
  }

  Future<void> deleteItem(dynamic key) async {
    await _box.delete(key);
  }

  /// Delete all queued punches of a given method — e.g. cancel a queued
  /// WiFi OUT when the user reconnects to the registered office wifi
  /// (the disconnect that triggered it never actually happened).
  Future<void> deleteQueuedByMethod(String method) async {
    final queued = _box.values.where((p) => p.method == method).toList();
    for (final p in queued) {
      await _box.delete(p.key);
    }
  }

  DateTime? get lastPunchTime {
    final all = _box.values.toList();
    if (all.isEmpty) return null;
    all.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return all.first.createdAt;
  }

  /// Last punch time persisted to Hive — survives app restart, so the
  /// 5-minute offline cooldown is not bypassed by killing the app.
  DateTime? get persistedLastPunchTime {
    final raw = _cache.get(_lastPunchTimeKey) as String?;
    return raw != null ? DateTime.tryParse(raw) : null;
  }
}

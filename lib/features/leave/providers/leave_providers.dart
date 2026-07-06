import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../models/leave.dart';

// ── Leave Types ───────────────────────────────────────────────────────────────

final leaveTypesProvider = FutureProvider<List<LeaveType>>((ref) async {
  try {
    final dio = ref.read(dioClientProvider).dio;
    final response = await dio.get(ApiEndpoints.leaveTypes);
    final data = response.data['data'] as List<dynamic>? ?? [];
    return data
        .map((e) => LeaveType.fromJson(e as Map<String, dynamic>))
        .where((t) => t.id > 0)
        .toList();
  } catch (_) {
    return [];
  }
});

// ── Leave Balances ────────────────────────────────────────────────────────────

final leaveBalancesProvider = FutureProvider<List<LeaveBalance>>((ref) async {
  try {
    final dio = ref.read(dioClientProvider).dio;
    final response = await dio.get(ApiEndpoints.leaveBalances);
    final data = response.data['data'] as List<dynamic>? ?? [];
    return data
        .map((e) => LeaveBalance.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return [];
  }
});

// ── Leave Requests ────────────────────────────────────────────────────────────

final leaveRequestsProvider =
    AsyncNotifierProvider<LeaveRequestsNotifier, List<LeaveRequest>>(
  () => LeaveRequestsNotifier(),
);

class LeaveRequestsNotifier extends AsyncNotifier<List<LeaveRequest>> {
  @override
  Future<List<LeaveRequest>> build() => _fetch();

  Future<List<LeaveRequest>> _fetch() async {
    try {
      final dio = ref.read(dioClientProvider).dio;
      final response = await dio.get(ApiEndpoints.leaveList);
      final data = response.data['data'] as List<dynamic>? ?? [];
      return data
          .map((e) => LeaveRequest.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {
      return [];
    }
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }
}

// ── History filter ────────────────────────────────────────────────────────────

final leaveHistoryFilterProvider = StateProvider<String?>((ref) => null);

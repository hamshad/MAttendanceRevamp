import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../widgets/status_chip.dart';
import '../../../core/utils/date_time_utils.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

class RegularizationRecord {
  final int id;
  final DateTime requestedInTime;
  final DateTime requestedOutTime;
  final String reason;
  final String status;
  final DateTime createdAt;

  const RegularizationRecord({
    required this.id,
    required this.requestedInTime,
    required this.requestedOutTime,
    required this.reason,
    required this.status,
    required this.createdAt,
  });

  factory RegularizationRecord.fromJson(Map<String, dynamic> j) {
    return RegularizationRecord(
      id: j['id'] as int,

      requestedInTime: DateTime.parse(
        (j['requestedInTime'] as String).replaceAll('Z', ''),
      ),

      requestedOutTime: DateTime.parse(
        (j['requestedOutTime'] as String).replaceAll('Z', ''),
      ),

      reason: j['reason'] as String? ?? '',
      status: j['status'] as String? ?? 'Pending',

      createdAt: parseUtc(j['createdAt'] as String),
    );
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────

final regularizationListProvider =
    AsyncNotifierProvider<RegularizationNotifier, List<RegularizationRecord>>(
      () => RegularizationNotifier(),
    );

class RegularizationNotifier extends AsyncNotifier<List<RegularizationRecord>> {
  @override
  Future<List<RegularizationRecord>> build() => _fetch();

  Future<List<RegularizationRecord>> _fetch() async {
    try {
      final dio = ref.read(dioClientProvider).dio;
      final response = await dio.get(ApiEndpoints.regularizationList);
      final data = response.data['data'] as List<dynamic>? ?? [];
      return data
          .map((e) => RegularizationRecord.fromJson(e as Map<String, dynamic>))
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

// ── Screen ────────────────────────────────────────────────────────────────────

class RegularizationScreen extends ConsumerWidget {
  const RegularizationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listAsync = ref.watch(regularizationListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Regularization'),
        leading: const BackButton(),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showNewRequestSheet(context, ref),
        child: const Icon(Icons.add),
      ),
      body: listAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(
          child: Text('Could not load regularization requests.'),
        ),
        data: (items) {
          if (items.isEmpty) {
            return RefreshIndicator(
              onRefresh: () =>
                  ref.read(regularizationListProvider.notifier).refresh(),
              child: ListView(
                children: [
                  const SizedBox(height: 80),
                  const Center(
                    child: Text(
                      'No regularization requests yet.',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () =>
                ref.read(regularizationListProvider.notifier).refresh(),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _RegularizationCard(item: items[i]),
            ),
          );
        },
      ),
    );
  }

  void _showNewRequestSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _NewRequestSheet(
        onSubmitted: () =>
            ref.read(regularizationListProvider.notifier).refresh(),
      ),
    );
  }
}

// ── Card ──────────────────────────────────────────────────────────────────────

class _RegularizationCard extends StatelessWidget {
  final RegularizationRecord item;
  const _RegularizationCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _fmtDate(item.createdAt),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              StatusChip(status: item.status, type: StatusChipType.approval),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.login, size: 14, color: AppColors.success),
              const SizedBox(width: 4),
              Text(
                _fmtTime(item.requestedInTime),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.logout, size: 14, color: AppColors.error),
              const SizedBox(width: 4),
              Text(
                _fmtTime(item.requestedOutTime),
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            item.reason,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  String _fmtDate(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  String _fmtTime(DateTime d) {
    final h = d.hour;
    final m = d.minute.toString().padLeft(2, '0');
    final amPm = h >= 12 ? 'PM' : 'AM';
    final h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);

    return '$h12:$m $amPm';
  }
}

// ── New Request bottom sheet ───────────────────────────────────────────────────

class _NewRequestSheet extends ConsumerStatefulWidget {
  final VoidCallback onSubmitted;
  const _NewRequestSheet({required this.onSubmitted});

  @override
  ConsumerState<_NewRequestSheet> createState() => _NewRequestSheetState();
}

class _NewRequestSheetState extends ConsumerState<_NewRequestSheet> {
  final _reasonCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  DateTime? _date;
  TimeOfDay? _inTime;
  TimeOfDay? _outTime;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  DateTime? _combined(DateTime? date, TimeOfDay? time) {
    if (date == null || time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 90)),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime(bool isIn) async {
    final initial = isIn
        ? (_inTime ?? const TimeOfDay(hour: 9, minute: 0))
        : (_outTime ?? const TimeOfDay(hour: 18, minute: 0));
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    setState(() {
      if (isIn) {
        _inTime = picked;
      } else {
        _outTime = picked;
      }
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_date == null || _inTime == null || _outTime == null) {
      _showSnack('Please fill in date and both times.');
      return;
    }
    final inDt = _combined(_date, _inTime)!;
    final outDt = _combined(_date, _outTime)!;
    if (!outDt.isAfter(inDt)) {
      _showSnack('Out time must be after In time.');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final dio = ref.read(dioClientProvider).dio;
      await dio.post(
        ApiEndpoints.regularizationApply,
        data: {
          'requestedInTime': inDt.toIso8601String(),
          'requestedOutTime': outDt.toIso8601String(),
          'reason': _reasonCtrl.text.trim(),
        },
      );
      if (!mounted) return;
      Navigator.pop(context);
      widget.onSubmitted();
    } catch (e) {
      if (!mounted) return;
      _showSnack(_extractError(e));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  String _extractError(Object e) {
    try {
      final data = (e as dynamic).response?.data as Map?;
      return data?['message'] as String? ?? e.toString();
    } catch (_) {
      return e.toString();
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _fmtDate(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  String _fmtTime(TimeOfDay t) {
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final m = t.minute.toString().padLeft(2, '0');
    final amPm = t.period == DayPeriod.am ? 'AM' : 'PM';
    return '$h:$m $amPm';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'New Regularization Request',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Date
            _SheetLabel('Date'),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.calendar_today_outlined, size: 16),
              label: Text(_date == null ? 'Pick date' : _fmtDate(_date!)),
              style: OutlinedButton.styleFrom(
                alignment: Alignment.centerLeft,
                minimumSize: const Size(double.infinity, 44),
              ),
            ),
            const SizedBox(height: 12),

            // Times
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SheetLabel('In Time'),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: () => _pickTime(true),
                        icon: const Icon(
                          Icons.login,
                          size: 16,
                          color: AppColors.success,
                        ),
                        label: Text(
                          _inTime == null ? 'Pick time' : _fmtTime(_inTime!),
                        ),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 44),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SheetLabel('Out Time'),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: () => _pickTime(false),
                        icon: const Icon(
                          Icons.logout,
                          size: 16,
                          color: AppColors.error,
                        ),
                        label: Text(
                          _outTime == null ? 'Pick time' : _fmtTime(_outTime!),
                        ),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 44),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Reason
            _SheetLabel('Reason'),
            const SizedBox(height: 6),
            TextFormField(
              controller: _reasonCtrl,
              maxLines: 2,
              maxLength: 500,
              decoration: const InputDecoration(
                hintText: 'Explain why the time needs correction…',
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 16),

            ElevatedButton(
              onPressed: _isSubmitting ? null : _submit,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
              ),
              child: _isSubmitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('SUBMIT REQUEST'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetLabel extends StatelessWidget {
  final String text;
  const _SheetLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(color: AppColors.textSecondary),
  );
}

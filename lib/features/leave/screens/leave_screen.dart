import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../models/leave.dart';
import '../../../widgets/skeleton_loader.dart';
import '../../../widgets/status_chip.dart';
import '../providers/leave_providers.dart';

// ── Main screen ───────────────────────────────────────────────────────────────

class LeaveScreen extends ConsumerStatefulWidget {
  const LeaveScreen({super.key});

  @override
  ConsumerState<LeaveScreen> createState() => _LeaveScreenState();
}

class _LeaveScreenState extends ConsumerState<LeaveScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Leave'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'Apply'),
            Tab(text: 'History'),
            Tab(text: 'Balances'),
          ],
          labelColor: theme.colorScheme.primary,
          indicatorColor: theme.colorScheme.primary,
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _ApplyTab(onSuccess: () => _tab.animateTo(1)),
          const _HistoryTab(),
          const _BalancesTab(),
        ],
      ),
    );
  }
}

// ── Apply tab ─────────────────────────────────────────────────────────────────

class _ApplyTab extends ConsumerStatefulWidget {
  final VoidCallback onSuccess;
  const _ApplyTab({required this.onSuccess});

  @override
  ConsumerState<_ApplyTab> createState() => _ApplyTabState();
}

class _ApplyTabState extends ConsumerState<_ApplyTab> {
  final _reasonCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  LeaveType? _selectedType;
  DateTime? _fromDate;
  DateTime? _toDate;
  bool _isHalfDay = false;
  String _halfDayPeriod = 'FirstHalf';
  bool _isSubmitting = false;

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  int get _calculatedDays {
    if (_fromDate == null || _toDate == null) return 0;
    if (_isHalfDay) return 0; // server calculates
    final days = _toDate!.difference(_fromDate!).inDays + 1;
    return days < 0 ? 0 : days;
  }

  LeaveBalance? _balanceFor(List<LeaveBalance> balances) {
    if (_selectedType == null) return null;
    try {
      return balances
          .firstWhere((b) => b.leaveTypeId == _selectedType!.id);
    } catch (_) {
      return null;
    }
  }

  Future<void> _pickDate(bool isFrom) async {
    final initial = isFrom
        ? (_fromDate ?? DateTime.now())
        : (_toDate ?? _fromDate ?? DateTime.now());
    final first = isFrom ? DateTime.now() : (_fromDate ?? DateTime.now());

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;

    setState(() {
      if (isFrom) {
        _fromDate = picked;
        if (_toDate != null && _toDate!.isBefore(picked)) {
          _toDate = picked;
        }
      } else {
        _toDate = picked;
      }
    });
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    if (_selectedType == null) {
      _showSnack('Please select a leave type.');
      return;
    }
    if (_fromDate == null || _toDate == null) {
      _showSnack('Please select the date range.');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final dio = ref.read(dioClientProvider).dio;
      await dio.post(ApiEndpoints.leaveApply, data: {
        'leaveTypeId': _selectedType!.id,
        'fromDate': _fromDate!.toIso8601String(),
        'toDate': _toDate!.toIso8601String(),
        'isHalfDay': _isHalfDay,
        if (_isHalfDay) 'halfDayPeriod': _halfDayPeriod,
        'reason': _reasonCtrl.text.trim(),
      });

      if (!mounted) return;
      _showSnack('Leave request submitted!', success: true);
      ref.invalidate(leaveRequestsProvider);
      ref.invalidate(leaveBalancesProvider);

      // Reset form
      setState(() {
        _selectedType = null;
        _fromDate = null;
        _toDate = null;
        _isHalfDay = false;
        _halfDayPeriod = 'FirstHalf';
      });
      _reasonCtrl.clear();

      widget.onSuccess();
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

  void _showSnack(String msg, {bool success = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: success ? AppColors.success : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final typesAsync = ref.watch(leaveTypesProvider);
    final balancesAsync = ref.watch(leaveBalancesProvider);
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Leave type picker ──────────────────────────────────────────
            _FieldLabel('Leave Type'),
            const SizedBox(height: 8),
            typesAsync.when(
              loading: () => const _Skeleton(height: 56),
              error: (_, _) => const _ErrorNote('Could not load leave types.'),
              data: (types) => DropdownButtonFormField<LeaveType>(
                initialValue: _selectedType,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.flight_takeoff_outlined),
                ),
                hint: const Text('Select leave type'),
                items: types
                    .map((t) => DropdownMenuItem(
                          value: t,
                          child: Text(t.displayName),
                        ))
                    .toList(),
                onChanged: (t) => setState(() => _selectedType = t),
                validator: (v) => v == null ? 'Required' : null,
              ),
            ),
            const SizedBox(height: 12),

            // ── Balance hint ───────────────────────────────────────────────
            balancesAsync.maybeWhen(
              data: (balances) {
                final bal = _balanceFor(balances);
                if (bal == null) return const SizedBox.shrink();
                return _BalanceHint(balance: bal);
              },
              orElse: () => const SizedBox.shrink(),
            ),
            const SizedBox(height: 16),

            // ── Date range ─────────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _FieldLabel('From'),
                      const SizedBox(height: 8),
                      _DateButton(
                        date: _fromDate,
                        onTap: () => _pickDate(true),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _FieldLabel('To'),
                      const SizedBox(height: 8),
                      _DateButton(
                        date: _toDate,
                        onTap: () => _pickDate(false),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // ── Days count hint ────────────────────────────────────────────
            if (_fromDate != null && _toDate != null && !_isHalfDay)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _calculatedDays == 1
                      ? '1 day'
                      : '$_calculatedDays days',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),

            // ── Half-day toggle ────────────────────────────────────────────
            SwitchListTile(
              value: _isHalfDay,
              onChanged: (v) => setState(() => _isHalfDay = v),
              title: const Text('Half Day'),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
            if (_isHalfDay) ...[
              const SizedBox(height: 4),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'FirstHalf', label: Text('First Half')),
                  ButtonSegment(value: 'SecondHalf', label: Text('Second Half')),
                ],
                selected: {_halfDayPeriod},
                onSelectionChanged: (s) =>
                    setState(() => _halfDayPeriod = s.first),
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(height: 8),
            ],

            const SizedBox(height: 8),

            // ── Reason ─────────────────────────────────────────────────────
            _FieldLabel('Reason'),
            const SizedBox(height: 8),
            TextFormField(
              controller: _reasonCtrl,
              maxLines: 3,
              maxLength: 500,
              decoration: const InputDecoration(
                hintText: 'Enter reason for leave…',
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 24),

            // ── Submit ─────────────────────────────────────────────────────
            ElevatedButton.icon(
              onPressed: _isSubmitting ? null : _submit,
              icon: _isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.send_outlined),
              label: Text(_isSubmitting ? 'Submitting…' : 'APPLY FOR LEAVE'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 52),
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: AppColors.graySubtle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Balance hint ──────────────────────────────────────────────────────────────

class _BalanceHint extends StatelessWidget {
  final LeaveBalance balance;
  const _BalanceHint({required this.balance});

  @override
  Widget build(BuildContext context) {
    final avail = balance.available;
    final color = avail > 0 ? AppColors.success : AppColors.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Row(
        children: [
          Icon(Icons.account_balance_wallet_outlined, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            '${balance.leaveTypeName}: ${_fmt(avail)} day${avail == 1 ? '' : 's'} available',
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  String _fmt(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

// ── History tab ───────────────────────────────────────────────────────────────

class _HistoryTab extends ConsumerWidget {
  const _HistoryTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requestsAsync = ref.watch(leaveRequestsProvider);
    final filter = ref.watch(leaveHistoryFilterProvider);

    return Column(
      children: [
        // ── Filter chips ─────────────────────────────────────────────────
        _FilterBar(
          selected: filter,
          onSelect: (f) =>
              ref.read(leaveHistoryFilterProvider.notifier).state = f,
        ),
        // ── List ─────────────────────────────────────────────────────────
        Expanded(
          child: requestsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) =>
                const Center(child: Text('Could not load leave history.')),
            data: (all) {
              final filtered = filter == null
                  ? all
                  : all.where((r) => r.status == filter).toList();
              if (filtered.isEmpty) {
                return Center(
                  child: Text(
                    filter == null
                        ? 'No leave requests yet.'
                        : 'No $filter leaves.',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 14),
                  ),
                );
              }
              return RefreshIndicator(
                onRefresh: () =>
                    ref.read(leaveRequestsProvider.notifier).refresh(),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (ctx, i) =>
                      _LeaveRequestCard(request: filtered[i], ref: ref),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ── Filter bar ────────────────────────────────────────────────────────────────

class _FilterBar extends StatelessWidget {
  final String? selected;
  final ValueChanged<String?> onSelect;

  const _FilterBar({required this.selected, required this.onSelect});

  static const _filters = [null, 'Pending', 'Approved', 'Rejected', 'Cancelled'];
  static const _labels = ['All', 'Pending', 'Approved', 'Rejected', 'Cancelled'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: const Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final isSelected = selected == _filters[i];
          return Center(
            child: ChoiceChip(
              label: Text(_labels[i]),
              selected: isSelected,
              onSelected: (_) => onSelect(_filters[i]),
              selectedColor: theme.colorScheme.primary,
              labelStyle: TextStyle(
                color: isSelected ? Colors.white : theme.colorScheme.onSurface,
                fontSize: 12,
              ),
              side: BorderSide(
                color: isSelected
                    ? theme.colorScheme.primary
                    : AppColors.border,
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          );
        },
      ),
    );
  }
}

// ── Leave request card ────────────────────────────────────────────────────────

class _LeaveRequestCard extends StatefulWidget {
  final LeaveRequest request;
  final WidgetRef ref;
  const _LeaveRequestCard({required this.request, required this.ref});

  @override
  State<_LeaveRequestCard> createState() => _LeaveRequestCardState();
}

class _LeaveRequestCardState extends State<_LeaveRequestCard> {
  bool _cancelling = false;

  Future<void> _cancel() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Leave?'),
        content: const Text('This will cancel your leave request.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('No')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Yes, Cancel',
                  style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _cancelling = true);
    try {
      final dio = widget.ref.read(dioClientProvider).dio;
      await dio.patch(ApiEndpoints.cancelLeave(widget.request.id));
      widget.ref.read(leaveRequestsProvider.notifier).refresh();
      widget.ref.invalidate(leaveBalancesProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_extractError(e))),
      );
    } finally {
      if (mounted) setState(() => _cancelling = false);
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

  @override
  Widget build(BuildContext context) {
    final r = widget.request;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  r.leaveTypeName ?? 'Leave',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 15),
                ),
              ),
              StatusChip(status: r.status, type: StatusChipType.approval),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${_fmtDate(r.fromDate)} – ${_fmtDate(r.toDate)}'
            '${r.isHalfDay ? '  (${r.halfDayPeriod?.replaceAll("Half", " Half") ?? "Half Day"})' : ''}',
            style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            '${_fmtDays(r.leaveDays)}  •  ${r.reason}',
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (r.canCancel) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: _cancelling
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      onPressed: _cancel,
                      style: TextButton.styleFrom(
                          foregroundColor: AppColors.error,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8)),
                      child: const Text('Cancel Request'),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  String _fmtDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[d.month - 1]} ${d.day}';
  }

  String _fmtDays(double d) {
    if (d == 0.5) return '½ day';
    if (d == 1) return '1 day';
    return d == d.truncateToDouble()
        ? '${d.toInt()} days'
        : '${d.toStringAsFixed(1)} days';
  }
}

// ── Balances tab ──────────────────────────────────────────────────────────────

class _BalancesTab extends ConsumerWidget {
  const _BalancesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balancesAsync = ref.watch(leaveBalancesProvider);

    return balancesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) =>
          const Center(child: Text('Could not load balances.')),
      data: (balances) {
        if (balances.isEmpty) {
          return const Center(
            child: Text(
              'No leave balances found.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () => ref.refresh(leaveBalancesProvider.future),
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
            itemCount: balances.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (_, i) => _BalanceCard(balance: balances[i]),
          ),
        );
      },
    );
  }
}

class _BalanceCard extends StatelessWidget {
  final LeaveBalance balance;
  const _BalanceCard({required this.balance});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avail = balance.available;
    final availColor = avail > 0 ? AppColors.success : AppColors.error;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ────────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: Text(
                  balance.leaveTypeName,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: balance.isPaid
                      ? AppColors.infoSubtle
                      : AppColors.graySubtle,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  balance.isPaid ? 'Paid' : 'Unpaid',
                  style: TextStyle(
                    fontSize: 11,
                    color: balance.isPaid ? AppColors.info : AppColors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // ── Stats row ──────────────────────────────────────────────────
          Row(
            children: [
              _StatCell(
                  label: 'Entitled', value: balance.entitled, color: null),
              _StatCell(label: 'Used', value: balance.used, color: null),
              _StatCell(
                  label: 'Available',
                  value: avail,
                  color: availColor,
                  bold: true),
              if (balance.carryForwarded > 0)
                _StatCell(
                    label: 'Carry Fwd',
                    value: balance.carryForwarded,
                    color: AppColors.purple),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  final String label;
  final double value;
  final Color? color;
  final bool bold;

  const _StatCell({
    required this.label,
    required this.value,
    required this.color,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.textPrimary;
    final v = value == value.truncateToDouble()
        ? value.toInt().toString()
        : value.toStringAsFixed(1);
    return Expanded(
      child: Column(
        children: [
          Text(
            v,
            style: TextStyle(
              fontSize: 20,
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
              color: c,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

// ── Date button ───────────────────────────────────────────────────────────────

class _DateButton extends StatelessWidget {
  final DateTime? date;
  final VoidCallback onTap;
  const _DateButton({required this.date, required this.onTap});

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  @override
  Widget build(BuildContext context) {
    final label = date == null
        ? 'Pick date'
        : '${_months[date!.month - 1]} ${date!.day}, ${date!.year}';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: date == null ? AppColors.textSecondary : null,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: AppColors.textSecondary),
      );
}

class _Skeleton extends StatelessWidget {
  final double height;
  const _Skeleton({required this.height});

  @override
  Widget build(BuildContext context) => SkeletonLoader(
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      );
}

class _ErrorNote extends StatelessWidget {
  final String message;
  const _ErrorNote(this.message);

  @override
  Widget build(BuildContext context) => Text(
        message,
        style: const TextStyle(color: AppColors.error, fontSize: 13),
      );
}

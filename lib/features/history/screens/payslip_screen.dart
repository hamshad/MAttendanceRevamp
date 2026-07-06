import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/theme/app_colors.dart';

// ── Models ────────────────────────────────────────────────────────────────────

class PayslipComponent {
  final String name;
  final double amount;

  const PayslipComponent({required this.name, required this.amount});

  factory PayslipComponent.fromJson(Map<String, dynamic> j) =>
      PayslipComponent(
        name: j['name'] as String,
        amount: (j['amount'] as num).toDouble(),
      );
}

class AttendanceSummary {
  final int presentDays;
  final int absentDays;
  final int leaveDays;
  final int lateDays;
  final int overtimeMinutes;

  const AttendanceSummary({
    required this.presentDays,
    required this.absentDays,
    required this.leaveDays,
    required this.lateDays,
    required this.overtimeMinutes,
  });

  factory AttendanceSummary.fromJson(Map<String, dynamic> j) =>
      AttendanceSummary(
        presentDays: j['presentDays'] as int? ?? 0,
        absentDays: j['absentDays'] as int? ?? 0,
        leaveDays: j['leaveDays'] as int? ?? 0,
        lateDays: j['lateDays'] as int? ?? 0,
        overtimeMinutes:
            j['totalOvertimeMinutes'] as int? ?? 0,
      );
}

class Payslip {
  final String fullName;
  final String? department;
  final int month;
  final int year;
  final List<PayslipComponent> earnings;
  final List<PayslipComponent> deductions;
  final double grossEarnings;
  final double totalDeductions;
  final double netPayable;
  final AttendanceSummary attendanceSummary;

  const Payslip({
    required this.fullName,
    this.department,
    required this.month,
    required this.year,
    required this.earnings,
    required this.deductions,
    required this.grossEarnings,
    required this.totalDeductions,
    required this.netPayable,
    required this.attendanceSummary,
  });

  factory Payslip.fromJson(Map<String, dynamic> j) => Payslip(
        fullName: j['fullName'] as String? ?? '',
        department: j['department'] as String?,
        month: j['month'] as int,
        year: j['year'] as int,
        earnings: (j['earnings'] as List<dynamic>? ?? [])
            .map((e) =>
                PayslipComponent.fromJson(e as Map<String, dynamic>))
            .toList(),
        deductions: (j['deductions'] as List<dynamic>? ?? [])
            .map((e) =>
                PayslipComponent.fromJson(e as Map<String, dynamic>))
            .toList(),
        grossEarnings: (j['grossEarnings'] as num).toDouble(),
        totalDeductions: (j['totalDeductions'] as num).toDouble(),
        netPayable: (j['netPayable'] as num).toDouble(),
        attendanceSummary: AttendanceSummary.fromJson(
            j['attendanceSummary'] as Map<String, dynamic>? ?? {}),
      );
}

// ── Provider ──────────────────────────────────────────────────────────────────

final _payslipMonthProvider = StateProvider<int>(
    (ref) => DateTime.now().month == 1 ? 12 : DateTime.now().month - 1);
final _payslipYearProvider = StateProvider<int>((ref) {
  final now = DateTime.now();
  return now.month == 1 ? now.year - 1 : now.year;
});

final payslipProvider =
    FutureProvider.autoDispose<Payslip?>((ref) async {
  final month = ref.watch(_payslipMonthProvider);
  final year = ref.watch(_payslipYearProvider);
  try {
    final dio = ref.read(dioClientProvider).dio;
    final response = await dio.get(
      ApiEndpoints.payslip,
      queryParameters: {'year': year, 'month': month},
    );
    final data = response.data['data'] as Map<String, dynamic>?;
    return data != null ? Payslip.fromJson(data) : null;
  } catch (_) {
    return null;
  }
});

// ── Screen ────────────────────────────────────────────────────────────────────

class PayslipScreen extends ConsumerWidget {
  const PayslipScreen({super.key});

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December'
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(_payslipMonthProvider);
    final year = ref.watch(_payslipYearProvider);
    final payslipAsync = ref.watch(payslipProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Payslip'),
        leading: const BackButton(),
      ),
      body: Column(
        children: [
          // ── Month / Year selector ──────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              border:
                  Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => _prevMonth(ref, month, year),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_monthNames[month - 1]} $year',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _canGoNext(month, year)
                      ? () => _nextMonth(ref, month, year)
                      : null,
                ),
              ],
            ),
          ),

          // ── Content ────────────────────────────────────────────────────
          Expanded(
            child: payslipAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (_, _) => const Center(
                child: Text(
                  'Could not load payslip.',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              data: (payslip) {
                if (payslip == null) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.receipt_long_outlined,
                            size: 48, color: AppColors.gray),
                        const SizedBox(height: 12),
                        Text(
                          'No payslip for ${_monthNames[month - 1]} $year.',
                          style: const TextStyle(color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  );
                }
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Net payable hero
                      _NetPayableCard(
                          payslip: payslip, theme: theme),
                      const SizedBox(height: 20),

                      // Attendance summary
                      _SectionTitle('Attendance Summary'),
                      const SizedBox(height: 10),
                      _AttendanceSummaryCard(
                          summary: payslip.attendanceSummary),
                      const SizedBox(height: 20),

                      // Earnings
                      _SectionTitle('Earnings'),
                      const SizedBox(height: 10),
                      _ComponentTable(
                        rows: payslip.earnings,
                        totalLabel: 'Gross Earnings',
                        total: payslip.grossEarnings,
                        accentColor: AppColors.success,
                      ),
                      const SizedBox(height: 20),

                      // Deductions
                      if (payslip.deductions.isNotEmpty) ...[
                        _SectionTitle('Deductions'),
                        const SizedBox(height: 10),
                        _ComponentTable(
                          rows: payslip.deductions,
                          totalLabel: 'Total Deductions',
                          total: payslip.totalDeductions,
                          accentColor: AppColors.error,
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  bool _canGoNext(int month, int year) {
    final now = DateTime.now();
    return DateTime(year, month).isBefore(DateTime(now.year, now.month - 1));
  }

  void _prevMonth(WidgetRef ref, int month, int year) {
    if (month == 1) {
      ref.read(_payslipMonthProvider.notifier).state = 12;
      ref.read(_payslipYearProvider.notifier).state = year - 1;
    } else {
      ref.read(_payslipMonthProvider.notifier).state = month - 1;
    }
  }

  void _nextMonth(WidgetRef ref, int month, int year) {
    if (month == 12) {
      ref.read(_payslipMonthProvider.notifier).state = 1;
      ref.read(_payslipYearProvider.notifier).state = year + 1;
    } else {
      ref.read(_payslipMonthProvider.notifier).state = month + 1;
    }
  }
}

// ── Net payable hero ──────────────────────────────────────────────────────────

class _NetPayableCard extends StatelessWidget {
  final Payslip payslip;
  final ThemeData theme;
  const _NetPayableCard({required this.payslip, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primary,
            theme.colorScheme.primary.withAlpha(200),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(payslip.fullName,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16)),
          if (payslip.department != null)
            Text(payslip.department!,
                style: const TextStyle(
                    color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 16),
          const Text('Net Payable',
              style: TextStyle(color: Colors.white70, fontSize: 13)),
          Text(
            '₹${_fmt(payslip.netPayable)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(double v) {
    if (v >= 100000) {
      return v.toStringAsFixed(0).replaceAllMapped(
            RegExp(r'(\d)(?=(\d{2})+(?!\d))'),
            (m) => '${m[0]},',
          );
    }
    return v.toStringAsFixed(2);
  }
}

// ── Attendance summary card ───────────────────────────────────────────────────

class _AttendanceSummaryCard extends StatelessWidget {
  final AttendanceSummary summary;
  const _AttendanceSummaryCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    final otH = summary.overtimeMinutes ~/ 60;
    final otM = summary.overtimeMinutes % 60;
    final otLabel = otH > 0 ? '${otH}h ${otM}m' : '${otM}m';

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _SummaryChip(
            label: 'Present',
            value: '${summary.presentDays}d',
            color: AppColors.success),
        _SummaryChip(
            label: 'Absent',
            value: '${summary.absentDays}d',
            color: AppColors.error),
        _SummaryChip(
            label: 'Leave',
            value: '${summary.leaveDays}d',
            color: AppColors.info),
        _SummaryChip(
            label: 'Late',
            value: '${summary.lateDays}d',
            color: AppColors.warning),
        _SummaryChip(
            label: 'OT',
            value: otLabel,
            color: AppColors.purple),
      ],
    );
  }
}

class _SummaryChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _SummaryChip(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

// ── Component table ───────────────────────────────────────────────────────────

class _ComponentTable extends StatelessWidget {
  final List<PayslipComponent> rows;
  final String totalLabel;
  final double total;
  final Color accentColor;

  const _ComponentTable({
    required this.rows,
    required this.totalLabel,
    required this.total,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          ...rows.asMap().entries.map((entry) {
            final i = entry.key;
            final row = entry.value;
            return Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                border: i < rows.length - 1
                    ? const Border(
                        bottom:
                            BorderSide(color: AppColors.border))
                    : null,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(row.name,
                        style: const TextStyle(fontSize: 14)),
                  ),
                  Text(
                    '₹${row.amount.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              ),
            );
          }),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: accentColor.withAlpha(15),
              borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(10)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(totalLabel,
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: accentColor,
                          fontSize: 14)),
                ),
                Text(
                  '₹${total.toStringAsFixed(2)}',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: accentColor,
                      fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
      );
}

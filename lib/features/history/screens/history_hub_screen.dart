import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/dashboard/providers/dashboard_providers.dart';
import '../../../features/tracking/screens/my_field_tracking_screen.dart';
import 'attendance_history_screen.dart';
import 'regularization_screen.dart';
import 'wfh_screen.dart';
import 'payslip_screen.dart';

class HistoryHubScreen extends ConsumerWidget {
  const HistoryHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowFieldTracking =
        ref.watch(accessPermissionsProvider).value?.allowFieldTracking ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _HubTile(
            icon: Icons.edit_calendar_outlined,
            color: Colors.indigo.shade600,
            title: 'Attendance History',
            subtitle: 'Monthly calendar view',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const AttendanceHistoryScreen()),
            ),
          ),
          const SizedBox(height: 12),
          _HubTile(
            icon: Icons.assignment_outlined,
            color: Colors.orange.shade700,
            title: 'Regularization',
            subtitle: 'Correct missed punch times',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const RegularizationScreen()),
            ),
          ),
          const SizedBox(height: 12),
          _HubTile(
            icon: Icons.home_work_outlined,
            color: Colors.teal.shade600,
            title: 'WFH Check-in',
            subtitle: 'Log work-from-home sessions',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const WFHScreen()),
            ),
          ),
          const SizedBox(height: 12),
          _HubTile(
            icon: Icons.receipt_long_outlined,
            color: Colors.green.shade700,
            title: 'Payslip',
            subtitle: 'View monthly salary breakdown',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PayslipScreen()),
            ),
          ),
          if (allowFieldTracking) ...[
            const SizedBox(height: 12),
            _HubTile(
              icon: Icons.route_outlined,
              color: Colors.deepPurple.shade600,
              title: 'Field Tracking Report',
              subtitle: 'Distance travelled by date — export for reimbursement',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const MyFieldTrackingScreen()),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HubTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _HubTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.grey.shade200),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(6),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withAlpha(25),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }
}

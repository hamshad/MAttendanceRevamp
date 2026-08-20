import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/office_data_service.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../models/client_site.dart';
import '../../../models/office.dart';
import '../../dashboard/providers/dashboard_providers.dart';

/// Nested screen under "Geofence Auto-Punch" in the profile tab.
///
/// Shows the static geofence zones the auto-punch engine monitors — two
/// sections: **Office** and **Client Sites** (client sites only when the user
/// is granted the client-site permission), plus a privacy explainer.
class GeofencePlacesScreen extends ConsumerStatefulWidget {
  const GeofencePlacesScreen({super.key});

  @override
  ConsumerState<GeofencePlacesScreen> createState() => _GeofencePlacesScreenState();
}

class _GeofencePlacesScreenState extends ConsumerState<GeofencePlacesScreen> {
  List<Office> _offices = [];
  List<ClientSite> _clientSites = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
    });

    final perms = ref.read(accessPermissionsProvider).value;
    final sitePerm = perms?.allowClientSite ?? false;

    final dataService = ref.read(officeDataServiceProvider);
    try {
      await dataService.fetchAndSaveOffices();
      if (sitePerm) {
        await dataService.fetchAndSaveClientSites();
      }
      if (!mounted) return;
      setState(() {
        _offices = OfficeDataService.getCachedOffices() ?? [];
        _clientSites = sitePerm ? OfficeDataService.getCachedClientSites() ?? [] : [];
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _offices = OfficeDataService.getCachedOffices() ?? [];
        _clientSites = sitePerm ? OfficeDataService.getCachedClientSites() ?? [] : [];
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final sitePerm = ref.watch(accessPermissionsProvider).value?.allowClientSite ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('Geofence Places')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  // ── Privacy explainer ─────────────────────────────────────
                  _PrivacyCard(isDark: isDark),
                  const SizedBox(height: 24),

                  // ── Office section ────────────────────────────────────────
                  _SectionHeader(
                    icon: Icons.business_outlined,
                    title: 'Office',
                    count: _offices.length,
                  ),
                  const SizedBox(height: 8),
                  if (_offices.isEmpty)
                    const _EmptyHint(
                      icon: Icons.business_outlined,
                      text: 'No office zones configured.',
                    )
                  else
                    ..._offices.map((o) => _ZoneTile(
                          isDark: isDark,
                          name: o.name.isEmpty ? 'Office #${o.id}' : o.name,
                          address: o.hasCoordinates
                              ? '${o.latitude!.toStringAsFixed(5)}, ${o.longitude!.toStringAsFixed(5)}'
                              : 'No coordinates set',
                          radius: o.geofenceRadius,
                        )),

                  const SizedBox(height: 24),

                  // ── Client Sites section ──────────────────────────────────
                  _SectionHeader(
                    icon: Icons.location_city_outlined,
                    title: 'Client Sites',
                    count: _clientSites.length,
                  ),
                  const SizedBox(height: 8),
                  if (!sitePerm)
                    const _EmptyHint(
                      icon: Icons.lock_outline,
                      text: 'Not granted — ask your admin to enable the '
                          'client-site permission.',
                    )
                  else if (_clientSites.isEmpty)
                    const _EmptyHint(
                      icon: Icons.location_city_outlined,
                      text: 'No active client sites configured.',
                    )
                  else
                    ..._clientSites.map((s) => _ZoneTile(
                          isDark: isDark,
                          name: s.siteName,
                          address: s.address ?? 'No address provided',
                          radius: s.radiusMeters,
                          coords:
                              '${s.latitude.toStringAsFixed(5)}, ${s.longitude.toStringAsFixed(5)}',
                        )),
                ],
              ),
            ),
    );
  }
}

// ── Privacy card ──────────────────────────────────────────────────────────────

class _PrivacyCard extends StatelessWidget {
  final bool isDark;
  const _PrivacyCard({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final primary = isDark ? AppColors.darkPrimary : AppColors.primary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: primary.withAlpha(14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: primary.withAlpha(50)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, color: primary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Privacy Notice',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(color: primary, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  'These static zones are used only to decide when to auto-punch. '
                  'Your exact location is not tracked continuously and nothing about '
                  'your movement is sent to the backend — only the punch event '
                  '(with the zone you were near) is recorded.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Sections ──────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final int count;
  const _SectionHeader({required this.icon, required this.title, required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Row(
      children: [
        Icon(icon,
            size: 18,
            color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkBorder : AppColors.graySubtle,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(
              color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

class _ZoneTile extends StatelessWidget {
  final bool isDark;
  final String name;
  final String address;
  final int? radius;
  final String? coords;
  const _ZoneTile({
    required this.isDark,
    required this.name,
    required this.address,
    this.radius,
    this.coords,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (radius != null)
                Row(
                  children: [
                    Icon(
                      Icons.radio_button_checked,
                      size: 14,
                      color: isDark ? AppColors.darkInfo : AppColors.info,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$radius m',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            coords != null ? '$address\n$coords' : address,
            style: theme.textTheme.bodySmall?.copyWith(
              color: isDark ? AppColors.darkMuted : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty hints ───────────────────────────────────────────────────────────────

class _EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyHint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.graySubtle,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: isDark ? AppColors.darkMuted : AppColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: isDark ? AppColors.darkMuted : AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

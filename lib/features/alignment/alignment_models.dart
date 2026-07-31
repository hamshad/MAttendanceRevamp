import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/theme/app_colors.dart';

/// Severity of an alignment alert. Critical alerts affect whether the
/// employee gets punched in/out at all; warnings degrade reliability.
enum AlignmentSeverity {
  critical,
  warning,
}

/// What the "Fix it" button should open.
enum AlignmentFix {
  none, // just informational — user fixes it manually
  locationSettings, // phone Settings → Location
  appSettings, // phone Settings → Apps → Mattendance
}

/// A single user-alignment alert. Written in plain, non-technical words
/// (audience: employees who may not know what GPS/SSID/BSSID mean).
class AlignmentAlert {
  final String id;
  final AlignmentSeverity severity;
  final String title;
  final String message;
  final String? fixLabel;
  final AlignmentFix fix;

  const AlignmentAlert({
    required this.id,
    required this.severity,
    required this.title,
    required this.message,
    this.fixLabel,
    this.fix = AlignmentFix.none,
  });

  Color get color => severity == AlignmentSeverity.critical
      ? AppColors.error
      : AppColors.warning;

  Color get subtleColor => severity == AlignmentSeverity.critical
      ? AppColors.errorSubtle
      : AppColors.warningSubtle;

  IconData get icon => severity == AlignmentSeverity.critical
      ? Icons.error_outline
      : Icons.warning_amber_rounded;

  Future<void> runFix() async {
    switch (fix) {
      case AlignmentFix.locationSettings:
        await Geolocator.openLocationSettings();
        break;
      case AlignmentFix.appSettings:
        await Geolocator.openAppSettings();
        break;
      case AlignmentFix.none:
        break;
    }
  }
}

// NOTE: message strings are the EMPLOYEE-facing copy. Keep them plain —
// no "BSSID", no "monitoring paused", no jargon. Say what broke, why it
// matters for attendance, and how to fix it in tap-path steps.

class AlignmentAlerts {
  static const gpsOff = AlignmentAlert(
    id: 'gps_off',
    severity: AlignmentSeverity.critical,
    title: 'GPS is off',
    message:
        'Auto punch won\u2019t work and you could be marked absent even at the '
        'office. Turn Location back on.',
    fixLabel: 'Turn on GPS',
    fix: AlignmentFix.locationSettings,
  );

  static const permissionNotAlways = AlignmentAlert(
    id: 'permission_not_always',
    severity: AlignmentSeverity.critical,
    title: 'Allow location "All the time"',
    message:
        'Right now auto punch only works while the app is open on screen. '
        'If you close the app, it stops working.',
    fixLabel: 'Open app settings',
    fix: AlignmentFix.appSettings,
  );

  static const noConnectivity = AlignmentAlert(
    id: 'no_connectivity',
    severity: AlignmentSeverity.warning,
    title: 'No network (airplane mode?)',
    message:
        'Attendance can\u2019t send or receive right now. WiFi punches will be '
        'saved and sent when you\u2019re back online.',
    fixLabel: 'OK',
    fix: AlignmentFix.none,
  );

  static const wifiHidden = AlignmentAlert(
    id: 'wifi_hidden',
    severity: AlignmentSeverity.warning,
    title: 'Connected to WiFi, but the app can\u2019t read it',
    message:
        'This happens when Location is off. Turn it on so auto punch can '
        'confirm you\u2019re on the office network.',
    fixLabel: 'Turn on GPS',
    fix: AlignmentFix.locationSettings,
  );
}

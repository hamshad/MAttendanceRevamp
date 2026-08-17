import 'package:geolocator/geolocator.dart';

/// OUT-band containment with the accuracy TRUST FLOOR (honesty rule,
/// strengthened 2026-08-17 after a false OUT at 68m beyond the radius
/// while the user was confidently INSIDE).
///
/// A fix counts as "outside" only when BOTH hold:
///   - beyond the fixed OUT band (radius + fixed 25m slack — user spec,
///     accuracy never WIDENS the band), AND
///   - its claimed accuracy is at most the band distance (radius +
///     slack).  Fused Android fixes blend wifi/cell positions that can
///     claim 100-500m accuracy and jump 300-500m; two such fixes passed
///     the old dist-only pairwise check and fabricated an OUT.  Real GPS
///     while walking claims 5-20m — always passes.
///
/// Mirrors the IN trust floor (`accuracy <= radius`): untrusted fixes
/// DEFER the punch to the next check (OS EXIT crossing path / 15-min
/// net) — a deferred OUT beats a fake OUT.
///
/// Pure function — unit-testable.  Zone passed as primitives to avoid a
/// dependency cycle with GeofenceMonitor (where GeofenceZone lives).
bool isOutsideOfficeBand(
  Position fix, {
  required double zoneLatitude,
  required double zoneLongitude,
  required double zoneRadius,
  double slackM = 25,
}) {
  final dist = Geolocator.distanceBetween(
      fix.latitude, fix.longitude, zoneLatitude, zoneLongitude);
  return dist > zoneRadius + slackM &&
      fix.accuracy <= zoneRadius + slackM;
}

/// Development-only feature flags.
///
/// ⚠️  Set [kDevMode] to `false` before shipping a production build.
///     When `true` a live debug console is overlaid on the Field Tracking
///     screen, showing GPS state, pipeline decisions, ping status, and
///     geofence proximity.
class DevFlags {
  DevFlags._();

  /// Master switch for all development overlays.
  /// Toggle this to `false` to hide every dev-only UI element.
  static const bool kDevMode = false;
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'alignment_monitor.dart';

/// Main-isolate alignment watchdog. Started lazily on first watch (MainShell
/// post-frame callback). Lives for the whole app session — the singleton is
/// NOT disposed when a widget stops watching (logout/login would otherwise
/// kill its streams; start() is idempotent and resumes it).
final alignmentMonitorProvider = ChangeNotifierProvider<AlignmentMonitor>(
  (ref) => AlignmentMonitor.instance..start(),
);

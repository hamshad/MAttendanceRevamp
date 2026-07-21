import 'dart:io';

import 'package:permission_handler/permission_handler.dart';
import '../utils/app_logger.dart';

class PermissionService {
  PermissionService._();
  static final instance = PermissionService._();

  /// Checks if background location (Allow all the time) is granted.
  Future<bool> hasBackgroundLocation() async {
    final status = await Permission.locationAlways.status;
    return status.isGranted;
  }

  /// Requests background location permission.
  ///
  /// Android: two explicit steps (foreground "while using", then background
  /// "all the time" via a settings redirect on Android 11+).
  ///
  /// iOS: location permissions are NOT granted the same way. iOS only ever
  /// shows the **When In Use** prompt from the foreground. The "Always"
  /// upgrade is offered by the OS as a *second* dialog AFTER When In Use is
  /// granted, and if the user already denied, iOS will NOT re-prompt — it
  /// sends the app to Settings. Requesting `Permission.location` (which maps
  /// to When In Use) and then immediately `Permission.locationAlways` from
  /// the foreground is the wrong order on iOS and silently returns denied.
  Future<bool> requestBackgroundLocation() async {
    if (Platform.isIOS) {
      return _requestBackgroundLocationIos();
    }

    AppLogger.i('PERMISSIONS: Requesting foreground location...');
    final foregroundStatus = await Permission.location.request();

    if (!foregroundStatus.isGranted) {
      AppLogger.w('PERMISSIONS: Foreground location denied');
      return false;
    }

    AppLogger.i('PERMISSIONS: Requesting background location (Allow all the time)...');
    final backgroundStatus = await Permission.locationAlways.request();

    if (backgroundStatus.isGranted) {
      AppLogger.i('PERMISSIONS: Background location granted');
      return true;
    } else {
      AppLogger.w('PERMISSIONS: Background location denied');
      return false;
    }
  }

  Future<bool> _requestBackgroundLocationIos() async {
    AppLogger.i('PERMISSIONS[iOS]: Requesting When In Use location...');
    var whenInUse = await Permission.locationWhenInUse.status;
    if (whenInUse.isDenied) {
      whenInUse = await Permission.locationWhenInUse.request();
    }

    if (whenInUse.isPermanentlyDenied) {
      // iOS will not re-prompt; the user must enable it in Settings.
      AppLogger.w('PERMISSIONS[iOS]: When In Use permanently denied → open settings');
      await openAppSettings();
      return await hasBackgroundLocation();
    }

    if (!whenInUse.isGranted) {
      AppLogger.w('PERMISSIONS[iOS]: When In Use denied');
      return false;
    }

    AppLogger.i('PERMISSIONS[iOS]: Requesting Always (Allow all the time)...');
    var always = await Permission.locationAlways.status;
    if (!always.isGranted) {
      always = await Permission.locationAlways.request();
    }

    if (always.isGranted || always.isLimited) {
      AppLogger.i('PERMISSIONS[iOS]: Background location granted');
      return true;
    }

    if (always.isPermanentlyDenied) {
      AppLogger.w('PERMISSIONS[iOS]: Always permanently denied → open settings');
      await openAppSettings();
      return await hasBackgroundLocation();
    }

    AppLogger.w('PERMISSIONS[iOS]: Background location denied');
    return false;
  }

  /// Checks if foreground location (while using the app) is granted.
  Future<bool> hasForegroundLocation() async {
    if (Platform.isIOS) {
      final status = await Permission.locationWhenInUse.status;
      return status.isGranted || status.isLimited;
    }
    final status = await Permission.location.status;
    return status.isGranted;
  }

  /// Requests foreground location permission only (while using the app).
  Future<bool> requestForegroundLocation() async {
    AppLogger.i('PERMISSIONS: Requesting foreground location...');
    final status = Platform.isIOS
        ? await Permission.locationWhenInUse.request()
        : await Permission.location.request();
    if (status.isGranted) {
      AppLogger.i('PERMISSIONS: Foreground location granted');
      return true;
    } else {
      AppLogger.w('PERMISSIONS: Foreground location denied');
      return false;
    }
  }

  /// Checks if Activity Recognition is granted (needed for geofence efficiency).
  Future<bool> hasActivityRecognition() async {
    final status = await Permission.activityRecognition.status;
    return status.isGranted;
  }

  Future<bool> requestActivityRecognition() async {
    final status = await Permission.activityRecognition.request();
    return status.isGranted;
  }
}

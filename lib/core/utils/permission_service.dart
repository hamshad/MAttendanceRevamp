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
  /// On Android, this usually requires two steps: 
  /// 1. Request foreground (while using)
  /// 2. Request background (all the time)
  Future<bool> requestBackgroundLocation() async {
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

  /// Checks if foreground location (while using the app) is granted.
  Future<bool> hasForegroundLocation() async {
    final status = await Permission.location.status;
    return status.isGranted;
  }

  /// Requests foreground location permission only (while using the app).
  Future<bool> requestForegroundLocation() async {
    AppLogger.i('PERMISSIONS: Requesting foreground location...');
    final status = await Permission.location.request();
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

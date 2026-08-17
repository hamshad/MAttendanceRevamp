import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/punch/services/oem_keep_alive_service.dart';

/// Intercepts every `POST /attendance/punch` response and syncs punch state
/// to SharedPreferences key `gf_last_punch_type` / `gf_last_punch_time`.
///
/// This is the SINGLE source of truth for punch direction across all
/// isolates — manual, geofence, WiFi, foreground, background.
/// Both [GeofencePunchHandler] and [WifiBackgroundWorker] read these
/// keys to gate duplicate punches.
class PunchStateInterceptor extends Interceptor {
  static const _punchPath = 'attendance/punch';

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _syncIfPunch(response.requestOptions, response.statusCode);
    handler.next(response);
  }

  @override
  void onError(DioException error, ErrorInterceptorHandler handler) {
    if (_isPunchRequest(error.requestOptions)) {
      final body = error.response?.data as Map?;
      final msg = (body?['message'] as String? ?? '').toLowerCase();
      if (msg.contains('duplicate') || msg.contains('already recorded')) {
        // Server already accepted the punch — sync state
        _syncDirection(error.requestOptions);
      }
    }
    handler.next(error);
  }

  void _syncIfPunch(RequestOptions options, int? status) {
    if (_isPunchRequest(options) && (status == 200 || status == 201)) {
      _syncDirection(options);
    }
  }

  bool _isPunchRequest(RequestOptions options) {
    return options.method == 'POST' && options.path.contains(_punchPath);
  }

  void _syncDirection(RequestOptions options) {
    final data = options.data;
    if (data == null) return;

    final direction = (data is Map) ? data['Direction'] as String? : null;
    if (direction == null || direction.isEmpty) return;

    // Fire-and-forget: never block the response chain
    SharedPreferences.getInstance().then((prefs) async {
      await prefs.setString('gf_last_punch_type', direction);
      await prefs.setString(
        'gf_last_punch_time',
        DateTime.now().toIso8601String(),
      );
      // Keep-alive FGS is punch-state lifecycle: a manual / wifi / offline
      // punch OUT must close the FGS (banner), a manual IN must start the
      // walk-out monitor.  No-op on transition absence.
      await OemKeepAliveService.syncToPunchState();
    });
  }
}

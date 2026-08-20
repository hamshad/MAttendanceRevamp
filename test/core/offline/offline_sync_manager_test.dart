import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:mattendance_mobile/core/offline/offline_sync_manager.dart';
import 'package:mattendance_mobile/core/utils/constants.dart';
import 'package:mattendance_mobile/models/offline_punch.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Points Hive.initFlutter (inside executeSyncTask) at a stable temp dir.
class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);

  @override
  Future<String?> getApplicationDocumentsPath() async => dir;

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// Mock dio for the sync task: answers todayStatus + counts punch POSTs.
class _MockSyncDio extends Interceptor {
  Map<String, dynamic>? status;
  bool failStatus = false;
  int punchCalls = 0;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.path.endsWith('/status')) {
      if (failStatus) {
        handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            error: 'down',
          ),
        );
      } else {
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: {'data': status ?? _noPunches()},
          ),
        );
      }
      return;
    }
    if (options.path.endsWith('/punch')) {
      punchCalls++;
      handler.resolve(
        Response(requestOptions: options, statusCode: 200, data: {'message': 'ok'}),
      );
      return;
    }
    handler.next(options);
  }
}

Map<String, dynamic> _noPunches() => {
      'empId': 1,
      'fullName': 'Test',
      'date': '2026-08-08',
      'status': 'Present',
      'firstInTime': null,
      'lastOutTime': null,
      'workMinutes': 0,
      'breakMinutes': 0,
      'isLateIn': false,
      'isOnBreak': false,
      'currentShift': 'Morning',
      'officeName': 'HQ',
      'todaysPunches': <Map<String, dynamic>>[],
    };

Map<String, dynamic> _punchedIn() {
  final s = _noPunches();
  s['firstInTime'] = '2026-08-08T09:00:00.000Z';
  (s['todaysPunches'] as List).add({
    'id': 1,
    'punchTime': '2026-08-08T09:00:00.000Z',
    'punchType': 'In',
    'method': 'Biometric',
  });
  return s;
}

Dio _dioWith(_MockSyncDio mock) =>
    Dio(BaseOptions(baseUrl: 'https://api.mattendance.com'))
      ..interceptors.add(mock);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String tempDir;
  late _MockSyncDio mock;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('osync_test').path;
    PathProviderPlatform.instance = _FakePathProvider(tempDir);
    mock = _MockSyncDio();
    SharedPreferences.setMockInitialValues({
      'bg_access_token': 'token',
      'bg_refresh_token': 'refresh',
    });

    Hive.init(tempDir);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(OfflinePunchAdapter());
    }
    await Hive.openBox<OfflinePunch>(AppConstants.offlinePunchBox);
    await Hive.openBox(AppConstants.cacheBox);
    await Hive.openBox(AppConstants.tokenBackupBox);
  });

  tearDown(() async {
    await Hive.close();
    Directory(tempDir).deleteSync(recursive: true);
  });

  Future<OfflinePunch> enqueue({
    required String method,
    required String direction,
    DateTime? createdAt,
  }) async {
    final box = Hive.box<OfflinePunch>(AppConstants.offlinePunchBox);
    final punch = OfflinePunch()
      ..method = method
      ..direction = direction
      ..latitude = 19.8761
      ..longitude = 75.34
      ..createdAt = createdAt ?? DateTime.now()
      ..retryCount = 0;
    await box.add(punch);
    return punch;
  }

  Box<OfflinePunch> box() =>
      Hive.box<OfflinePunch>(AppConstants.offlinePunchBox);

  test('queued auto IN covered by biometric → dropped, no POST', () async {
    await enqueue(method: 'GeofenceAuto', direction: 'In');
    mock.status = _punchedIn();

    await OfflineSyncManager.executeSyncTask(testDio: _dioWith(mock));

    expect(box().length, 0);
    expect(mock.punchCalls, 0);
  });

  test('queued auto IN still needed → POSTed, deleted, local state synced',
      () async {
    await enqueue(method: 'GeofenceAuto', direction: 'In');
    mock.status = _noPunches();

    await OfflineSyncManager.executeSyncTask(testDio: _dioWith(mock));

    expect(mock.punchCalls, 1);
    expect(box().length, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('gf_last_punch_type'), 'In');
  });

  test('queued auto IN older than TTL → dropped even if server agrees',
      () async {
    await enqueue(
      method: 'GeofenceAuto',
      direction: 'In',
      createdAt: DateTime.now().subtract(const Duration(minutes: 16)),
    );
    mock.status = _noPunches();

    await OfflineSyncManager.executeSyncTask(testDio: _dioWith(mock));

    expect(box().length, 0);
    expect(mock.punchCalls, 0);
  });

  test('manual GPS IN covered by biometric → dropped (gate applies to all)',
      () async {
    await enqueue(method: 'GPS', direction: 'In');
    mock.status = _punchedIn();

    await OfflineSyncManager.executeSyncTask(testDio: _dioWith(mock));

    expect(box().length, 0);
    expect(mock.punchCalls, 0);
  });

  test('manual GPS IN still needed → POSTed + local state synced', () async {
    await enqueue(method: 'GPS', direction: 'In');
    mock.status = _noPunches();

    await OfflineSyncManager.executeSyncTask(testDio: _dioWith(mock));

    expect(mock.punchCalls, 1);
    expect(box().length, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('gf_last_punch_type'), 'In');
  });

  test('queued OUT success → local state set to Out', () async {
    await enqueue(method: 'WiFi', direction: 'Out');
    mock.status = _punchedIn(); // user was IN → OUT is valid

    await OfflineSyncManager.executeSyncTask(testDio: _dioWith(mock));

    expect(mock.punchCalls, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('gf_last_punch_type'), 'Out');
  });

  test('server truth unreachable → punch kept, retryCount bumped', () async {
    await enqueue(method: 'GeofenceAuto', direction: 'In');
    mock.failStatus = true;

    await OfflineSyncManager.executeSyncTask(testDio: _dioWith(mock));

    expect(box().length, 1);
    expect(box().values.first.retryCount, 1);
    expect(mock.punchCalls, 0);
  });
}

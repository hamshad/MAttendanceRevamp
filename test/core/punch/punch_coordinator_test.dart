import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mattendance_mobile/core/punch/punch_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mock Dio that answers `todayStatus` with a controllable payload and
/// counts status fetches (for cache TTL assertions).
class _MockStatusDio extends Interceptor {
  Map<String, dynamic>? status;
  bool failStatus = false;
  int statusCalls = 0;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.path.endsWith('/status')) {
      statusCalls++;
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
            data: {'data': status ?? _status()},
          ),
        );
      }
      return;
    }
    handler.next(options);
  }
}

Dio _dioWith(_MockStatusDio mock) =>
    Dio(BaseOptions(baseUrl: 'https://api.mattendance.com'))
      ..interceptors.add(mock);

Map<String, dynamic> _status({
  bool onBreak = false,
  List<Map<String, dynamic>> punches = const [],
  String? firstIn,
  String? lastOut,
}) =>
    {
      'empId': 1,
      'fullName': 'Test',
      'date': '2026-08-08',
      'status': 'Present',
      'firstInTime': firstIn,
      'lastOutTime': lastOut,
      'workMinutes': 0,
      'breakMinutes': 0,
      'isLateIn': false,
      'isOnBreak': onBreak,
      'currentShift': 'Morning',
      'officeName': 'HQ',
      'todaysPunches': punches,
    };

Map<String, dynamic> _punch(String type, {int id = 1}) => {
      'id': id,
      'punchTime': '2026-08-08T09:00:00.000Z',
      'punchType': type,
      'method': 'Biometric',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockStatusDio mock;

  setUp(() {
    mock = _MockStatusDio();
    SharedPreferences.setMockInitialValues({});
  });

  group('Decision', () {
    test('last In, want In → duplicate', () async {
      mock.status = _status(punches: [_punch('In')]);
      expect(
        await PunchCoordinator.check(dio: _dioWith(mock), direction: 'In'),
        PunchCheck.duplicate,
      );
    });

    test('last Out, want In → valid', () async {
      mock.status = _status(punches: [_punch('In'), _punch('Out')]);
      expect(
        await PunchCoordinator.check(dio: _dioWith(mock), direction: 'In'),
        PunchCheck.valid,
      );
    });

    test('last Out, want Out → duplicate', () async {
      mock.status = _status(punches: [_punch('Out')]);
      expect(
        await PunchCoordinator.check(dio: _dioWith(mock), direction: 'Out'),
        PunchCheck.duplicate,
      );
    });

    test('no punches, want In → valid (first punch)', () async {
      mock.status = _status();
      expect(
        await PunchCoordinator.check(dio: _dioWith(mock), direction: 'In'),
        PunchCheck.valid,
      );
    });

    test('no punches, want Out → blocked (no IN today)', () async {
      mock.status = _status();
      expect(
        await PunchCoordinator.check(dio: _dioWith(mock), direction: 'Out'),
        PunchCheck.blocked,
      );
    });

    test('on break, want In → blocked', () async {
      mock.status = _status(onBreak: true, punches: [_punch('BreakStart')]);
      expect(
        await PunchCoordinator.check(dio: _dioWith(mock), direction: 'In'),
        PunchCheck.blocked,
      );
    });

    test('on break, want Out → valid (leaving break)', () async {
      mock.status = _status(onBreak: true, punches: [_punch('BreakStart')]);
      expect(
        await PunchCoordinator.check(dio: _dioWith(mock), direction: 'Out'),
        PunchCheck.valid,
      );
    });

    test('empty timeline + firstIn set → last type In (fallback)', () async {
      mock.status = _status(firstIn: '2026-08-08T09:00:00.000Z');
      expect(
        await PunchCoordinator.check(dio: _dioWith(mock), direction: 'In'),
        PunchCheck.duplicate,
      );
    });

    test('server unreachable → undecided', () async {
      mock.failStatus = true;
      expect(
        await PunchCoordinator.check(dio: _dioWith(mock), direction: 'In'),
        PunchCheck.undecided,
      );
    });
  });

  group('Cache', () {
    test('second check within TTL skips network', () async {
      mock.status = _status(punches: [_punch('In')]);
      final dio = _dioWith(mock);

      expect(await PunchCoordinator.check(dio: dio, direction: 'In'),
          PunchCheck.duplicate);
      expect(await PunchCoordinator.check(dio: dio, direction: 'In'),
          PunchCheck.duplicate);
      expect(mock.statusCalls, 1);
    });

    test('different directions share the cache verdict', () async {
      mock.status = _status(punches: [_punch('In')]);
      final dio = _dioWith(mock);

      expect(await PunchCoordinator.check(dio: dio, direction: 'In'),
          PunchCheck.duplicate);
      expect(await PunchCoordinator.check(dio: dio, direction: 'Out'),
          PunchCheck.valid);
      expect(mock.statusCalls, 1);
    });

    test('expired cache refetches', () async {
      mock.status = _status(punches: [_punch('In')]);
      SharedPreferences.setMockInitialValues({
        'bg_server_status_ts':
            DateTime.now().subtract(const Duration(seconds: 30))
                .millisecondsSinceEpoch,
        'bg_server_last_type': 'Out',
      });
      final dio = _dioWith(mock);

      expect(await PunchCoordinator.check(dio: dio, direction: 'In'),
          PunchCheck.duplicate);
      expect(mock.statusCalls, 1);
    });
  });
}

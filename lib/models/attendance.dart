import '../core/utils/date_time_utils.dart';

class AttendanceDay {
  final int id;
  final DateTime attendanceDate;
  final String status;
  final DateTime? firstInTime;
  final DateTime? lastOutTime;
  final int workMinutes;
  final bool isLateIn;
  final int? lateByMinutes;
  final bool isEarlyOut;
  final String? shiftName;

  const AttendanceDay({
    required this.id,
    required this.attendanceDate,
    required this.status,
    this.firstInTime,
    this.lastOutTime,
    required this.workMinutes,
    required this.isLateIn,
    this.lateByMinutes,
    required this.isEarlyOut,
    this.shiftName,
  });

  factory AttendanceDay.fromJson(Map<String, dynamic> j) => AttendanceDay(
        id: j['id'] as int,
        attendanceDate: parseUtc(j['attendanceDate'] as String),
        status: j['status'] as String,
        firstInTime: parseUtcOrNull(j['firstInTime'] as String?),
        lastOutTime: parseUtcOrNull(j['lastOutTime'] as String?),
        workMinutes: j['workMinutes'] as int? ?? 0,
        isLateIn: j['isLateIn'] as bool? ?? false,
        lateByMinutes: j['lateByMinutes'] as int?,
        isEarlyOut: j['isEarlyOut'] as bool? ?? false,
        shiftName: j['shiftName'] as String?,
      );
}

class PunchSummary {
  final int id;
  final DateTime punchTime;
  final String punchType; // 'In', 'Out', 'BreakStart', 'BreakEnd'
  final String method;
  final int? distanceFromOffice;
  final bool? isInOffice;
  final String? remarks;

  const PunchSummary({
    required this.id,
    required this.punchTime,
    required this.punchType,
    required this.method,
    this.distanceFromOffice,
    this.isInOffice,
    this.remarks,
  });

  factory PunchSummary.fromJson(Map<String, dynamic> j) => PunchSummary(
        id: j['id'] as int,
        punchTime: parseUtc(j['punchTime'] as String),
        punchType: j['punchType'] as String,
        method: j['method'] as String,
        distanceFromOffice: j['distanceFromOffice'] as int?,
        isInOffice: j['isInOffice'] as bool?,
        remarks: j['remarks'] as String?,
      );

  bool get isIn => punchType == 'In';
  bool get isOut => punchType == 'Out';
  bool get isBreakStart => punchType == 'BreakStart';
  bool get isBreakEnd => punchType == 'BreakEnd';
}

class EmployeeStatus {
  final int empId;
  final String fullName;
  final String date;
  final String status; // 'Present', 'Absent', 'Leave', etc.
  final DateTime? firstInTime;
  final DateTime? lastOutTime;
  final int? workMinutes;
  final int? breakMinutes;
  final bool isLateIn;
  final int? lateByMinutes;
  final bool isOnBreak;
  final String? currentShift;
  final String? officeName;
  final List<PunchSummary> todaysPunches;

  const EmployeeStatus({
    required this.empId,
    required this.fullName,
    required this.date,
    required this.status,
    this.firstInTime,
    this.lastOutTime,
    this.workMinutes,
    this.breakMinutes,
    required this.isLateIn,
    this.lateByMinutes,
    required this.isOnBreak,
    this.currentShift,
    this.officeName,
    required this.todaysPunches,
  });

  factory EmployeeStatus.fromJson(Map<String, dynamic> j) => EmployeeStatus(
        empId: j['empId'] as int,
        fullName: j['fullName'] as String,
        date: j['date'] as String,
        status: j['status'] as String,
        firstInTime: parseUtcOrNull(j['firstInTime'] as String?),
        lastOutTime: parseUtcOrNull(j['lastOutTime'] as String?),
        workMinutes: j['workMinutes'] as int?,
        breakMinutes: j['breakMinutes'] as int?,
        isLateIn: j['isLateIn'] as bool? ?? false,
        lateByMinutes: j['lateByMinutes'] as int?,
        isOnBreak: j['isOnBreak'] as bool? ?? false,
        currentShift: j['currentShift'] as String?,
        officeName: j['officeName'] as String?,
        todaysPunches: (j['todaysPunches'] as List<dynamic>? ?? [])
            .map((p) => PunchSummary.fromJson(p as Map<String, dynamic>))
            .toList(),
      );

  // Derive current punch state from the latest punch record.
  // lastOutTime is NOT cleared on a re-punch-in (it always holds the last
  // punch-out time), so it cannot be used alone to determine live state.
  PunchSummary? get _latestPunch => todaysPunches.isEmpty
      ? null
      : todaysPunches.reduce(
          (a, b) => a.punchTime.isAfter(b.punchTime) ? a : b);

  bool get isPunchedIn {
    if (isOnBreak) return false;
    final last = _latestPunch;
    if (last != null) return last.punchType == 'In' || last.punchType == 'BreakEnd';
    return firstInTime != null && lastOutTime == null;
  }

  bool get isPunchedOut {
    final last = _latestPunch;
    if (last != null) return last.punchType == 'Out';
    return lastOutTime != null;
  }

  bool get hasNotPunchedIn => firstInTime == null && todaysPunches.isEmpty;

  String get workDuration {
    final mins = workMinutes ?? 0;
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h == 0) return '${m}m';
    return '${h}h ${m}m';
  }
}

class PunchResult {
  final bool success;
  final String? message;

  /// True when the server already has this punch (biometric machine /
  /// website) and the user must confirm before forcing it.  The UI shows a
  /// short confirm dialog instead of a plain failure.
  final bool isDuplicate;

  const PunchResult({
    required this.success,
    this.message,
    this.isDuplicate = false,
  });

  factory PunchResult.fromJson(Map<String, dynamic> j) => PunchResult(
        success: j['success'] as bool? ?? false,
        message: j['message'] as String?,
      );
}

class AccessPermissions {
  final bool allowGPS;
  final bool allowWiFi;
  final bool allowQRCode;
  final bool allowSelfie;
  final bool allowFingerprint;
  final bool allowWeb;
  final bool allowBluetooth;
  final bool allowNFC;
  final bool allowFaceRecog;
  final bool allowGeofenceAuto;
  final bool allowVoice;
  final bool allowClientSite;
  final bool allowBackgroundLocation;
  final bool allowBiometricMachine;
  final bool allowFieldTracking;

  const AccessPermissions({
    required this.allowGPS,
    required this.allowWiFi,
    required this.allowQRCode,
    required this.allowSelfie,
    required this.allowFingerprint,
    required this.allowWeb,
    required this.allowBluetooth,
    required this.allowNFC,
    required this.allowFaceRecog,
    required this.allowGeofenceAuto,
    required this.allowVoice,
    required this.allowClientSite,
    required this.allowBackgroundLocation,
    required this.allowBiometricMachine,
    required this.allowFieldTracking,
  });

  factory AccessPermissions.fromJson(Map<String, dynamic> j) => AccessPermissions(
        allowGPS: j['allowGPS'] as bool? ?? false,
        allowWiFi: j['allowWiFi'] as bool? ?? false,
        allowQRCode: j['allowQRCode'] as bool? ?? false,
        allowSelfie: j['allowSelfie'] as bool? ?? false,
        allowFingerprint: j['allowFingerprint'] as bool? ?? false,
        allowWeb: j['allowWeb'] as bool? ?? false,
        allowBluetooth: j['allowBluetooth'] as bool? ?? false,
        allowNFC: j['allowNFC'] as bool? ?? false,
        allowFaceRecog: j['allowFaceRecog'] as bool? ?? false,
        allowGeofenceAuto: j['allowGeofenceAuto'] as bool? ?? false,
        allowVoice: j['allowVoice'] as bool? ?? false,
        allowClientSite: j['allowClientSite'] as bool? ?? false,
        allowBackgroundLocation: j['allowBackgroundLocation'] as bool? ?? false,
        allowBiometricMachine: j['allowBiometricMachine'] as bool? ?? false,
        allowFieldTracking: j['allowFieldTracking'] as bool? ?? false,
      );

  // Returns list of method keys that are permitted (mobile methods only)
  List<String> get allowedMethods {
    return [
      if (allowGPS) 'GPS',
      if (allowWiFi) 'WiFi',
      if (allowQRCode) 'QRCode',
      if (allowSelfie) 'Selfie',
      if (allowBluetooth) 'Bluetooth',
      if (allowNFC) 'NFC',
      if (allowFaceRecog) 'FaceRecog',
      if (allowGeofenceAuto) 'GeofenceAuto',
      if (allowVoice) 'Voice',
      if (allowClientSite) 'ClientSite',
    ];
  }

  // Minimal fallback: only GPS + Selfie (creation defaults), used when the API is unreachable
  static AccessPermissions get defaultMinimal => const AccessPermissions(
        allowGPS: true,
        allowWiFi: false,
        allowQRCode: false,
        allowSelfie: true,
        allowFingerprint: false,
        allowWeb: false,
        allowBluetooth: false,
        allowNFC: false,
        allowFaceRecog: false,
        allowGeofenceAuto: false,
        allowVoice: false,
        allowClientSite: false,
        allowBackgroundLocation: false,
        allowBiometricMachine: false,
        allowFieldTracking: false,
      );

  static AccessPermissions get defaultAll => const AccessPermissions(
        allowGPS: true,
        allowWiFi: true,
        allowQRCode: true,
        allowSelfie: true,
        allowFingerprint: true,
        allowWeb: false,
        allowBluetooth: true,
        allowNFC: true,
        allowFaceRecog: true,
        allowGeofenceAuto: true,
        allowVoice: true,
        allowClientSite: true,
        allowBackgroundLocation: true,
        allowBiometricMachine: false,
        allowFieldTracking: true,
      );
}

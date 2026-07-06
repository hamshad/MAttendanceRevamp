import '../core/utils/date_time_utils.dart';

class LeaveType {
  final int id;
  final String typeName;
  final String? code;
  final bool isPaid;
  final bool isCarryForwardAllowed;
  final int? maxDaysPerYear;

  const LeaveType({
    required this.id,
    required this.typeName,
    this.code,
    required this.isPaid,
    required this.isCarryForwardAllowed,
    this.maxDaysPerYear,
  });

  factory LeaveType.fromJson(Map<String, dynamic> j) => LeaveType(
        id: j['id'] as int,
        typeName: j['typeName'] as String,
        code: j['code'] as String?,
        isPaid: j['isPaid'] as bool? ?? true,
        isCarryForwardAllowed: j['isCarryForwardAllowed'] as bool? ?? false,
        maxDaysPerYear: j['maxDaysPerYear'] as int?,
      );

  String get displayName => typeName;
}

class LeaveRequest {
  final int id;
  final int leaveTypeId;
  final String? leaveTypeName;
  final DateTime fromDate;
  final DateTime toDate;
  final bool isHalfDay;
  final String? halfDayPeriod;
  final double leaveDays;
  final String reason;
  final String status; // Pending, Approved, Rejected, Cancelled
  final DateTime createdAt;

  const LeaveRequest({
    required this.id,
    required this.leaveTypeId,
    this.leaveTypeName,
    required this.fromDate,
    required this.toDate,
    required this.isHalfDay,
    this.halfDayPeriod,
    required this.leaveDays,
    required this.reason,
    required this.status,
    required this.createdAt,
  });

  factory LeaveRequest.fromJson(Map<String, dynamic> j) => LeaveRequest(
        id: j['id'] as int,
        leaveTypeId: j['leaveTypeId'] as int,
        leaveTypeName: j['leaveTypeName'] as String?,
        fromDate: parseUtc(j['fromDate'] as String),
        toDate: parseUtc(j['toDate'] as String),
        isHalfDay: j['isHalfDay'] as bool? ?? false,
        halfDayPeriod: j['halfDayPeriod'] as String?,
        leaveDays: (j['leaveDays'] as num?)?.toDouble() ?? 0,
        reason: j['reason'] as String? ?? '',
        status: j['status'] as String? ?? 'Pending',
        createdAt: parseUtc(j['createdAt'] as String),
      );

  bool get canCancel => status == 'Pending' || status == 'Approved';
}

class LeaveBalance {
  final int leaveTypeId;
  final String leaveTypeName;
  final bool isPaid;
  final double openingBalance;
  final double credited;
  final double used;
  final double carryForwarded;
  final double closingBalance;

  const LeaveBalance({
    required this.leaveTypeId,
    required this.leaveTypeName,
    required this.isPaid,
    required this.openingBalance,
    required this.credited,
    required this.used,
    required this.carryForwarded,
    required this.closingBalance,
  });

  factory LeaveBalance.fromJson(Map<String, dynamic> j) => LeaveBalance(
        leaveTypeId: j['leaveTypeId'] as int,
        leaveTypeName: j['leaveTypeName'] as String,
        isPaid: j['isPaid'] as bool? ?? true,
        openingBalance: (j['openingBalance'] as num?)?.toDouble() ?? 0,
        credited: (j['credited'] as num?)?.toDouble() ?? 0,
        used: (j['used'] as num?)?.toDouble() ?? 0,
        carryForwarded: (j['carryForwarded'] as num?)?.toDouble() ?? 0,
        closingBalance: (j['closingBalance'] as num?)?.toDouble() ?? 0,
      );

  double get entitled => openingBalance + credited;
  double get available => closingBalance;
}

class Shift {
  final int id;
  final int orgId;
  final String name;
  final String startTime;
  final String endTime;
  final bool isOvernight;
  final int bufferMinutes;
  final int minBreakMinutes;
  final int? maxOvertimeMinutes;
  final bool isActive;
  final int activeEmployeeCount;

  const Shift({
    required this.id,
    required this.orgId,
    required this.name,
    required this.startTime,
    required this.endTime,
    required this.isOvernight,
    required this.bufferMinutes,
    required this.minBreakMinutes,
    this.maxOvertimeMinutes,
    required this.isActive,
    this.activeEmployeeCount = 0,
  });

  factory Shift.fromJson(Map<String, dynamic> j) => Shift(
        id: j['id'] as int,
        orgId: j['orgId'] as int,
        name: j['name'] as String,
        startTime: j['startTime'] as String,
        endTime: j['endTime'] as String,
        isOvernight: j['isOvernight'] as bool? ?? false,
        bufferMinutes: j['bufferMinutes'] as int? ?? 0,
        minBreakMinutes: j['minBreakMinutes'] as int? ?? 30,
        maxOvertimeMinutes: j['maxOvertimeMinutes'] as int?,
        isActive: j['isActive'] as bool? ?? true,
        activeEmployeeCount: j['activeEmployeeCount'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'orgId': orgId,
        'name': name,
        'startTime': startTime,
        'endTime': endTime,
        'isOvernight': isOvernight,
        'bufferMinutes': bufferMinutes,
        'minBreakMinutes': minBreakMinutes,
        'maxOvertimeMinutes': maxOvertimeMinutes,
        'isActive': isActive,
        'activeEmployeeCount': activeEmployeeCount,
      };

  DateTime get todayStart {
    final parts = startTime.split(':');
    final now = DateTime.now();
    return DateTime(
        now.year, now.month, now.day, int.parse(parts[0]), int.parse(parts[1]), parts.length > 2 ? int.parse(parts[2]) : 0);
  }

  DateTime get todayEnd {
    final parts = endTime.split(':');
    final now = DateTime.now();
    var end = DateTime(now.year, now.month, now.day, int.parse(parts[0]), int.parse(parts[1]), parts.length > 2 ? int.parse(parts[2]) : 0);
    if (isOvernight) end = end.add(const Duration(days: 1));
    return end;
  }

  bool canAutoPunchIn(DateTime time) => !time.isBefore(todayStart);

  bool get isActiveNow {
    final now = DateTime.now();
    return !now.isBefore(todayStart) && now.isBefore(todayEnd);
  }
}

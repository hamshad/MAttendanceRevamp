class ApiEndpoints {
  ApiEndpoints._();

  // Auth
  static const String login = '/api/v1/auth/login';
  static const String register = '/api/v1/auth/register';
  static const String refreshToken = '/api/v1/auth/refresh';
  static const String forgotPassword = '/api/v1/auth/forgot-password';
  static const String resetPassword = '/api/v1/auth/reset-password';
  static const String googleAuth = '/api/v1/auth/google';
  static const String logout = '/api/v1/auth/revoke';
  static const String me = '/api/v1/auth/me';

  // Attendance / Punch
  static const String punch = '/api/v1/attendance/punch';
  static const String todayStatus = '/api/v1/attendance/status';
  static const String attendanceHistory = '/api/v1/attendance/history';
  static const String monthlyCalendar = '/api/v1/attendance/monthly';

  // Breaks
  static const String startBreak = '/api/v1/breaks/start';
  static const String endBreak = '/api/v1/breaks/end';
  static const String todayBreaks = '/api/v1/breaks/today';

  // Leaves
  static const String leaveApply = '/api/v1/leaves';
  static const String leaveList = '/api/v1/leaves/my';
  static const String leaveBalances = '/api/v1/leave-balances';
  static const String leaveTypes = '/api/v1/leave-types';
  static String cancelLeave(int id) => '/api/v1/leaves/$id/cancel';

  // Regularization
  static const String regularizationApply = '/api/v1/attendance-regularizations';
  static const String regularizationList = '/api/v1/attendance-regularizations/my-requests';

  // WFH
  static const String wfhCheckin = '/api/v1/wfh-checkins';
  static const String wfhTodayLogs = '/api/v1/wfh-checkins/my/today';

  // Payroll
  static const String payslip = '/api/v1/payroll/me/payslip';

  // Notifications
  static const String notifications = '/api/v1/notifications/my';
  static String markNotificationRead(int id) => '/api/v1/notifications/$id/read';
  static const String markAllNotificationsRead = '/api/v1/notifications/read-all';
  static const String unreadCount = '/api/v1/notifications/my/unread-count';

  // Devices
  static const String registerDevice = '/api/v1/devices/register';

  // Employee
  static const String employeeProfile = '/api/v1/employees/my-profile';
  static const String accessPermissions = '/api/v1/employees/my/access-permissions';
  static const String myFaceData = '/api/v1/employees/my/face-data';
  static const String uploadMyPhoto = '/api/v1/employees/me/photo';

  // Shifts
  static const String shifts = '/api/v1/shifts';

  // Offices (geofence registration)
  static const String employeeOffices = '/api/v1/offices';
  static const String wifiRouters = '/api/v1/wifi-routers';

  // Client Sites (employee check-in)
  static const String clientSitesActive = '/api/v1/client-sites/active';

  // Field Tracking
  static const String trackingPing           = '/api/v1/tracking/ping';
  static const String myTrackingReport       = '/api/v1/tracking/my/report';
  static const String myTrackingReportExport = '/api/v1/tracking/my/report/export';
}

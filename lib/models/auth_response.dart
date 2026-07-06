import '../core/utils/date_time_utils.dart';

class AuthResponse {
  final String accessToken;
  final String refreshToken;
  final DateTime accessTokenExpiry;
  final int empId;
  final String fullName;
  final String email;
  final String role;
  final int orgId;
  final String orgName;
  final String? profilePhoto;

  const AuthResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.accessTokenExpiry,
    required this.empId,
    required this.fullName,
    required this.email,
    required this.role,
    required this.orgId,
    required this.orgName,
    this.profilePhoto,
  });

  factory AuthResponse.fromJson(Map<String, dynamic> json) => AuthResponse(
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String,
        accessTokenExpiry: parseUtc(json['accessTokenExpiry'] as String),
        empId: json['empId'] as int,
        fullName: json['fullName'] as String,
        email: json['email'] as String,
        role: json['role'] as String,
        orgId: json['orgId'] as int,
        orgName: json['orgName'] as String,
        profilePhoto: json['profilePhoto'] as String?,
      );
}

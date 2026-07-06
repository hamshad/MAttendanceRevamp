import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AppUser {
  final int empId;
  final String fullName;
  final String email;
  final String role;
  final int orgId;
  final String orgName;
  final String? profilePhoto;

  const AppUser({
    required this.empId,
    required this.fullName,
    required this.email,
    required this.role,
    required this.orgId,
    required this.orgName,
    this.profilePhoto,
  });

  AppUser copyWith({String? profilePhoto}) => AppUser(
        empId: empId,
        fullName: fullName,
        email: email,
        role: role,
        orgId: orgId,
        orgName: orgName,
        profilePhoto: profilePhoto ?? this.profilePhoto,
      );

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _empIdKey = 'user_emp_id';
  static const _fullNameKey = 'user_full_name';
  static const _emailKey = 'user_email';
  static const _roleKey = 'user_role';
  static const _orgIdKey = 'user_org_id';
  static const _orgNameKey = 'user_org_name';
  static const _profilePhotoKey = 'user_profile_photo';

  Future<void> save() async {
    await Future.wait([
      _storage.write(key: _empIdKey, value: empId.toString()),
      _storage.write(key: _fullNameKey, value: fullName),
      _storage.write(key: _emailKey, value: email),
      _storage.write(key: _roleKey, value: role),
      _storage.write(key: _orgIdKey, value: orgId.toString()),
      _storage.write(key: _orgNameKey, value: orgName),
      if (profilePhoto != null)
        _storage.write(key: _profilePhotoKey, value: profilePhoto!)
      else
        _storage.delete(key: _profilePhotoKey),
    ]);
  }

  static Future<AppUser?> load() async {
    final empIdStr = await _storage.read(key: _empIdKey);
    if (empIdStr == null) return null;

    return AppUser(
      empId: int.parse(empIdStr),
      fullName: await _storage.read(key: _fullNameKey) ?? '',
      email: await _storage.read(key: _emailKey) ?? '',
      role: await _storage.read(key: _roleKey) ?? '',
      orgId: int.parse(await _storage.read(key: _orgIdKey) ?? '0'),
      orgName: await _storage.read(key: _orgNameKey) ?? '',
      profilePhoto: await _storage.read(key: _profilePhotoKey),
    );
  }

  static Future<void> clear() async {
    await Future.wait([
      _storage.delete(key: _empIdKey),
      _storage.delete(key: _fullNameKey),
      _storage.delete(key: _emailKey),
      _storage.delete(key: _roleKey),
      _storage.delete(key: _orgIdKey),
      _storage.delete(key: _orgNameKey),
      _storage.delete(key: _profilePhotoKey),
    ]);
  }

  String get firstName => fullName.split(' ').first;
}

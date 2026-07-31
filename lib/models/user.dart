import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/utils/constants.dart';

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

  /// Hive fast-read mirror key.  Secure storage stays the source of truth
  /// on every write; Hive only makes [load] near-instant on app open.
  static const _hiveCacheKey = 'cached_user';

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
    _cacheToHive();
  }

  static Future<AppUser?> load() async {
    // Fast path: Hive mirror (near-zero latency — no secure-storage round
    // trips on every app open).
    final cached = _loadFromHive();
    if (cached != null) return cached;

    // Cold path: secure storage.  All reads run in PARALLEL — the previous
    // sequential version took ~7x a single encrypted read (~1-2s) on every
    // cold start, which kept the splash screen blank with a loader.
    final values = await Future.wait([
      _storage.read(key: _empIdKey),
      _storage.read(key: _fullNameKey),
      _storage.read(key: _emailKey),
      _storage.read(key: _roleKey),
      _storage.read(key: _orgIdKey),
      _storage.read(key: _orgNameKey),
      _storage.read(key: _profilePhotoKey),
    ]);
    final empIdStr = values[0];
    if (empIdStr == null) return null;

    final user = AppUser(
      empId: int.parse(empIdStr),
      fullName: values[1] ?? '',
      email: values[2] ?? '',
      role: values[3] ?? '',
      orgId: int.parse(values[4] ?? '0'),
      orgName: values[5] ?? '',
      profilePhoto: values[6],
    );
    // Backfill the mirror so the NEXT open skips secure storage entirely.
    user._cacheToHive();
    return user;
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
    try {
      await Hive.box(AppConstants.cacheBox).delete(_hiveCacheKey);
    } catch (_) {}
  }

  void _cacheToHive() {
    try {
      Hive.box(AppConstants.cacheBox).put(
        _hiveCacheKey,
        jsonEncode({
          'empId': empId,
          'fullName': fullName,
          'email': email,
          'role': role,
          'orgId': orgId,
          'orgName': orgName,
          'profilePhoto': profilePhoto,
        }),
      );
    } catch (_) {}
  }

  static AppUser? _loadFromHive() {
    try {
      final raw = Hive.box(AppConstants.cacheBox).get(_hiveCacheKey) as String?;
      if (raw == null) return null;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return AppUser(
        empId: j['empId'] as int? ?? 0,
        fullName: (j['fullName'] as String?) ?? '',
        email: (j['email'] as String?) ?? '',
        role: (j['role'] as String?) ?? '',
        orgId: j['orgId'] as int? ?? 0,
        orgName: (j['orgName'] as String?) ?? '',
        profilePhoto: j['profilePhoto'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  String get firstName => fullName.split(' ').first;
}

import 'package:hive_flutter/hive_flutter.dart';

part 'offline_punch.g.dart';

@HiveType(typeId: 0)
class OfflinePunch extends HiveObject {
  @HiveField(0)
  late String method;

  @HiveField(1)
  double? latitude;

  @HiveField(2)
  double? longitude;

  @HiveField(3)
  String? selfieBase64;

  @HiveField(4)
  String? qrToken;

  @HiveField(5)
  String? wifiMAC;

  @HiveField(6)
  String? wifiSSID;

  @HiveField(7)
  String? deviceId;

  @HiveField(8)
  String? beaconUUID;

  @HiveField(9)
  int? beaconMajor;

  @HiveField(10)
  int? beaconMinor;

  @HiveField(11)
  String? nfcTagId;

  @HiveField(12)
  String? faceEmbedding;

  @HiveField(13)
  String? direction; // 'In' | 'Out' | 'BreakStart' | 'BreakEnd'

  @HiveField(14)
  late DateTime createdAt;

  @HiveField(15)
  late int retryCount;

  @HiveField(16)
  String? errorMessage;
}

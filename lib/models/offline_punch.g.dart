// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'offline_punch.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class OfflinePunchAdapter extends TypeAdapter<OfflinePunch> {
  @override
  final int typeId = 0;

  @override
  OfflinePunch read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return OfflinePunch()
      ..method = fields[0] as String
      ..latitude = fields[1] as double?
      ..longitude = fields[2] as double?
      ..selfieBase64 = fields[3] as String?
      ..qrToken = fields[4] as String?
      ..wifiMAC = fields[5] as String?
      ..wifiSSID = fields[6] as String?
      ..deviceId = fields[7] as String?
      ..beaconUUID = fields[8] as String?
      ..beaconMajor = fields[9] as int?
      ..beaconMinor = fields[10] as int?
      ..nfcTagId = fields[11] as String?
      ..faceEmbedding = fields[12] as String?
      ..direction = fields[13] as String?
      ..createdAt = fields[14] as DateTime
      ..retryCount = fields[15] as int
      ..errorMessage = fields[16] as String?;
  }

  @override
  void write(BinaryWriter writer, OfflinePunch obj) {
    writer
      ..writeByte(17)
      ..writeByte(0)
      ..write(obj.method)
      ..writeByte(1)
      ..write(obj.latitude)
      ..writeByte(2)
      ..write(obj.longitude)
      ..writeByte(3)
      ..write(obj.selfieBase64)
      ..writeByte(4)
      ..write(obj.qrToken)
      ..writeByte(5)
      ..write(obj.wifiMAC)
      ..writeByte(6)
      ..write(obj.wifiSSID)
      ..writeByte(7)
      ..write(obj.deviceId)
      ..writeByte(8)
      ..write(obj.beaconUUID)
      ..writeByte(9)
      ..write(obj.beaconMajor)
      ..writeByte(10)
      ..write(obj.beaconMinor)
      ..writeByte(11)
      ..write(obj.nfcTagId)
      ..writeByte(12)
      ..write(obj.faceEmbedding)
      ..writeByte(13)
      ..write(obj.direction)
      ..writeByte(14)
      ..write(obj.createdAt)
      ..writeByte(15)
      ..write(obj.retryCount)
      ..writeByte(16)
      ..write(obj.errorMessage);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OfflinePunchAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

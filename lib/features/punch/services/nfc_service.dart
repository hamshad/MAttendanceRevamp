import 'package:nfc_manager/nfc_manager.dart';

// ── Service ──────────────────────────────────────────────────────────────────

/// NFC tag reader wrapping nfc_manager.
///
/// Platform setup required:
///   Android — AndroidManifest.xml:
///     `<uses-permission android:name="android.permission.NFC" />`
///     `<uses-feature android:name="android.hardware.nfc" android:required="false" />`
///
///   iOS — Info.plist: NFCReaderUsageDescription
///   iOS — Xcode: Near Field Communication Tag Reading capability
class NfcService {
  bool _sessionActive = false;

  /// Whether NFC hardware is available and enabled on this device.
  Future<bool> isAvailable() => NfcManager.instance.isAvailable();

  /// Start a foreground NFC session.
  ///
  /// [onTagRead]  fires with the colon-separated hex UID once a tag is tapped.
  /// [onError]    fires if the tag has no readable UID.
  ///
  /// The caller must call [stopSession] after processing the tag.
  Future<void> startSession({
    required void Function(String tagId) onTagRead,
    required void Function(String message) onError,
  }) async {
    _sessionActive = true;

    await NfcManager.instance.startSession(
      onDiscovered: (NfcTag tag) async {
        final tagId = _extractTagId(tag);
        if (tagId != null) {
          onTagRead(tagId);
        } else {
          onError('Could not read tag UID. Try a different NFC tag.');
        }
      },
    );
  }

  /// Stop the active NFC session. Safe to call when no session is running.
  Future<void> stopSession({String? iosAlertMessage}) async {
    if (!_sessionActive) return;
    _sessionActive = false;
    try {
      await NfcManager.instance.stopSession(
        alertMessage: iosAlertMessage,
      );
    } catch (_) {}
  }

  // ── UID extraction ────────────────────────────────────────────────────────

  /// Extract a colon-separated hex UID from the raw tag data map.
  ///
  /// nfc_manager v3.x exposes tag technology data via [NfcTag.data] as
  /// `Map<String, dynamic>`. Each tech key (e.g. 'nfca') contains an
  /// 'identifier' field with the raw UID bytes.
  String? _extractTagId(NfcTag tag) {
    // Try common tag technologies in order of prevalence.
    // Most office key fobs / attendance tags are NFC-A (MIFARE).
    for (final key in const ['nfca', 'nfcb', 'nfcf', 'nfcv', 'isodep']) {
      final tech = tag.data[key] as Map<String, dynamic>?;
      if (tech == null) continue;

      final raw = tech['identifier'];
      if (raw is List && raw.isNotEmpty) {
        return raw
            .map((b) =>
                (b as int).toRadixString(16).padLeft(2, '0').toUpperCase())
            .join(':');
      }
    }

    return null;
  }
}

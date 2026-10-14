import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../services/device_encryption_service.dart';
import '../services/device_service.dart';

/// Multi-device encrypted message payload.
///
/// Structure:
/// {
///   "version": "2.0",
///   "senderDeviceId": "device123",
///   "payloads": {
///     "deviceA": "base64cipher...",
///     "deviceB": "base64cipher...",
///     "deviceC": "base64cipher..."
///   },
///   "metadata": {
///     "timestamp": "...",
///     "messageId": "..."
///   }
/// }
class MultiDevicePayload {
  static const String currentVersion = '2.0';

  final String version;
  final String senderDeviceId;
  final Map<String, String> payloads;
  final Map<String, dynamic> metadata;

  MultiDevicePayload({
    required this.senderDeviceId,
    required this.payloads,
    this.metadata = const {},
    this.version = currentVersion,
  });

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'senderDeviceId': senderDeviceId,
      'payloads': payloads,
      'metadata': metadata,
    };
  }

  static MultiDevicePayload? fromJson(Map<String, dynamic> json) {
    try {
      return MultiDevicePayload(
        version: json['version'] as String? ?? '1.0',
        senderDeviceId: json['senderDeviceId'] as String? ?? '',
        payloads: Map<String, String>.from(json['payloads'] as Map? ?? {}),
        metadata: json['metadata'] as Map<String, dynamic>? ?? {},
      );
    } catch (e) {
      return null;
    }
  }

  /// Check if this device can decrypt this payload.
  bool canDecrypt(String deviceId) {
    return payloads.containsKey(deviceId);
  }

  /// Get encrypted payload for specific device.
  String? getPayloadForDevice(String deviceId) {
    return payloads[deviceId];
  }

  /// Check if this is a multi-device payload (v2.0+).
  bool get isMultiDevice => version.startsWith('2.');
}

/// Service for resolving device-specific payloads.
///
/// Handles the complexity of multi-device encryption:
/// - Encrypts for ALL recipient devices
/// - Selects appropriate payload for decryption
/// - Backward compatible with legacy messages
class DevicePayloadResolver {
  static void _dbg(String message) {
    assert(() {
      debugPrint('[ENCRYPT] $message');
      return true;
    }());
  }

  /// Encrypt message for multi-device delivery.
  ///
  /// Returns encrypted JSON string that can be stored in Firestore.
  /// Server cannot decrypt - only devices with matching private keys can.
  static Future<String?> encryptForMultiDevice({
    required String plaintext,
    required String recipientUid,
    String? senderDeviceId,
  }) async {
    _dbg('Encrypting for multi-device delivery');

    // Get current device ID
    final currentDeviceId = senderDeviceId ?? await DeviceService.getDeviceId();

    // Get recipient's device public keys
    final recipientDevices = await DeviceEncryptionService.getDevicePublicKeys(recipientUid);

    if (recipientDevices.isEmpty) {
      _dbg('No recipient devices found');
      return null;
    }

    // Get sender's device public keys (so sender can also decrypt on other devices)
    final senderUid = await _getCurrentUserId();
    if (senderUid != null) {
      final senderDevices = await DeviceEncryptionService.getDevicePublicKeys(senderUid);
      
      // Merge devices (recipient + sender)
      for (final entry in senderDevices.entries) {
        if (!recipientDevices.containsKey(entry.key)) {
          recipientDevices[entry.key] = entry.value;
        }
      }
    }

    // Encrypt for each device
    final payloads = <String, String>{};

    for (final entry in recipientDevices.entries) {
      final deviceId = entry.key;
      final publicKey = entry.value;

      try {
        final encrypted = await DeviceEncryptionService.encryptWithPublicKey(
          plaintext: plaintext,
          publicKey: publicKey,
        );

        if (encrypted != null) {
          payloads[deviceId] = encrypted;
          _dbg('Encrypted for device: $deviceId');
        }
      } catch (e) {
        _dbg('Failed to encrypt for device $deviceId: $e');
        // Continue with other devices
      }
    }

    if (payloads.isEmpty) {
      _dbg('Failed to encrypt for any device');
      return null;
    }

    // Create multi-device payload
    final multiDevicePayload = MultiDevicePayload(
      senderDeviceId: currentDeviceId,
      payloads: payloads,
      metadata: {
        'timestamp': DateTime.now().toIso8601String(),
        'deviceCount': payloads.length,
      },
    );

    // Serialize to JSON
    final jsonString = jsonEncode(multiDevicePayload.toJson());
    
    _dbg('Multi-device encryption complete: ${payloads.length} payloads');
    return jsonString;
  }

  /// Decrypt message for current device.
  ///
  /// Selects appropriate payload based on current device ID.
  /// Backward compatible with legacy single-device messages.
  static Future<String?> decryptForCurrentDevice(String encryptedJson) async {
    _dbg('Decrypting for current device');

    try {
      final json = jsonDecode(encryptedJson) as Map<String, dynamic>;
      
      // Check if multi-device payload
      final version = json['version'] as String? ?? '1.0';
      
      if (version.startsWith('2.')) {
        // Multi-device payload
        final payload = MultiDevicePayload.fromJson(json);
        if (payload == null) {
          _dbg('Failed to parse multi-device payload');
          return null;
        }

        // Get current device ID
        final currentDeviceId = await DeviceService.getDeviceId();

        // Check if payload exists for this device
        if (!payload.canDecrypt(currentDeviceId)) {
          _dbg('No payload available for device: $currentDeviceId');
          _dbg('Available devices: ${payload.payloads.keys.join(', ')}');
          return null;
        }

        // Get device-specific payload
        final devicePayload = payload.getPayloadForDevice(currentDeviceId)!;
        
        // Decrypt
        return await DeviceEncryptionService.decrypt(devicePayload);
      } else {
        // Legacy single-device payload - try direct decryption
        _dbg('Legacy payload detected, attempting direct decryption');
        return await DeviceEncryptionService.decrypt(encryptedJson);
      }
    } catch (e) {
      _dbg('Decryption failed: $e');
      return null;
    }
  }

  /// Get current user ID.
  static Future<String?> _getCurrentUserId() async {
    return FirebaseAuth.instance.currentUser?.uid;
  }

  /// Check if message can be decrypted by current device.
  static Future<bool> canDecrypt(String encryptedJson) async {
    try {
      final json = jsonDecode(encryptedJson) as Map<String, dynamic>;
      final version = json['version'] as String? ?? '1.0';

      if (version.startsWith('2.')) {
        final payload = MultiDevicePayload.fromJson(json);
        if (payload == null) return false;

        final currentDeviceId = await DeviceService.getDeviceId();
        return payload.canDecrypt(currentDeviceId);
      } else {
        // Legacy - assume we can try
        return true;
      }
    } catch (e) {
      return false;
    }
  }

  /// Get list of devices that can decrypt this message.
  static List<String> getRecipientDevices(String encryptedJson) {
    try {
      final json = jsonDecode(encryptedJson) as Map<String, dynamic>;
      final version = json['version'] as String? ?? '1.0';

      if (version.startsWith('2.')) {
        final payload = MultiDevicePayload.fromJson(json);
        return payload?.payloads.keys.toList() ?? [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }
}

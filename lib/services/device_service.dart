import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'device_trust_service.dart';
import 'session_lifecycle_manager.dart';
import 'session_validation_service.dart';

/// Device information model for multi-device registry
class DeviceInfo {
  final String deviceId;
  final String deviceName;
  final String? publicKey;
  final DateTime createdAt;
  final DateTime lastSeen;
  final bool trusted;
  final bool revoked;
  final String platform;
  final String appVersion;

  DeviceInfo({
    required this.deviceId,
    required this.deviceName,
    this.publicKey,
    required this.createdAt,
    required this.lastSeen,
    this.trusted = true,
    this.revoked = false,
    required this.platform,
    required this.appVersion,
  });

  Map<String, dynamic> toFirestore() {
    return {
      'deviceId': deviceId,
      'deviceName': deviceName,
      'publicKey': publicKey,
      'createdAt': Timestamp.fromDate(createdAt),
      'lastSeen': Timestamp.fromDate(lastSeen),
      'trusted': trusted,
      'revoked': revoked,
      'platform': platform,
      'appVersion': appVersion,
    };
  }

  static DeviceInfo fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    
    // Handle publicKey - could be String, Map, or null
    String? publicKey;
    final publicKeyData = data['publicKey'];
    if (publicKeyData is String) {
      publicKey = publicKeyData;
    } else if (publicKeyData is Map) {
      // If it's a map, convert to JSON string
      publicKey = jsonEncode(publicKeyData);
    } else {
      publicKey = null;
    }
    
    // Safely handle timestamps - they could be null or FieldValue
    DateTime createdAt;
    try {
      createdAt = (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
    } catch (e) {
      createdAt = DateTime.now();
    }
    
    DateTime lastSeen;
    try {
      lastSeen = (data['lastSeen'] as Timestamp?)?.toDate() ?? DateTime.now();
    } catch (e) {
      lastSeen = DateTime.now();
    }
    
    return DeviceInfo(
      deviceId: data['deviceId'] as String? ?? doc.id,
      deviceName: data['deviceName'] as String? ?? 'Unknown Device',
      publicKey: publicKey,
      createdAt: createdAt,
      lastSeen: lastSeen,
      trusted: data['trusted'] as bool? ?? true,
      revoked: data['revoked'] as bool? ?? false,
      platform: data['platform'] as String? ?? 'unknown',
      appVersion: data['appVersion'] as String? ?? 'unknown',
    );
  }
}

/// Service for managing multi-device registry
/// 
/// Each device gets a unique ID and is registered under:
/// users/{uid}/devices/{deviceId}
/// 
/// Security:
/// - Users can only access their own devices (enforced by Firestore rules)
/// - Device public keys are separate from account public key
/// - Revoked devices cannot access encrypted messages
class DeviceService {
  static final DeviceService _instance = DeviceService._internal();
  factory DeviceService() => _instance;
  DeviceService._internal();

  static final _firestore = FirebaseFirestore.instance;
  static const _storage = FlutterSecureStorage();

  static void _dbg(String message) {
    assert(() {
      debugPrint('[DEVICE] $message');
      return true;
    }());
  }

  /// Get or generate unique device ID
  static Future<String> getDeviceId() async {
    // Check cache first
    final cached = await _storage.read(key: 'device_id');
    if (cached != null) {
      _dbg('Using cached device ID: $cached');
      return cached;
    }

    // Generate new device ID
    final deviceInfo = DeviceInfoPlugin();
    String deviceId;

    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        deviceId = 'android_${androidInfo.id}_${DateTime.now().millisecondsSinceEpoch}';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        deviceId = 'ios_${iosInfo.identifierForVendor ?? DateTime.now().millisecondsSinceEpoch}_${DateTime.now().millisecondsSinceEpoch}';
      } else {
        deviceId = 'web_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().millisecondsSinceEpoch}';
      }
    } catch (e) {
      _dbg('Failed to get device info: $e');
      deviceId = 'unknown_${DateTime.now().millisecondsSinceEpoch}';
    }

    // Store device ID
    await _storage.write(key: 'device_id', value: deviceId);
    _dbg('Generated new device ID: $deviceId');

    return deviceId;
  }

  /// Get device name
  static Future<String> getDeviceName() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        // model is non-nullable on Android
        return androidInfo.model;
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        // name is non-nullable on iOS
        return iosInfo.name;
      }
    } catch (e) {
      _dbg('Failed to get device name: $e');
    }
    return 'Unknown Device';
  }

  /// Get platform
  static String getPlatform() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// Get app version
  static Future<String> getAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      return '${packageInfo.version}+${packageInfo.buildNumber}';
    } catch (e) {
      _dbg('Failed to get app version: $e');
      return 'unknown';
    }
  }

  /// Register this device
  /// 
  /// Called after successful login/registration
  /// Does NOT overwrite account public key
  /// 
  /// SECURITY: New devices are NOT automatically trusted. Trust is established
  /// via DeviceTrustService which requires approval from existing devices.
  /// 
  /// IDEMPOTENT: Safe to call multiple times. For existing devices, only
  /// updates lastSeen. For new devices, creates with trusted=false.
  static Future<void> registerDevice({
    required User user,
    String? devicePublicKey,
  }) async {
    _dbg('[DEVICE] registerDevice: START - uid: ${user.uid}');

    try {
      final deviceId = await getDeviceId();
      final deviceName = await getDeviceName();
      final platform = getPlatform();
      final appVersion = await getAppVersion();

      final now = DateTime.now();

      // Check if device already exists
      _dbg('[FIRESTORE] Checking if device exists: $deviceId');
      final existingDoc = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('devices')
          .doc(deviceId)
          .get();

      // Determine trust status
      bool trusted = false;
      if (existingDoc.exists) {
        final data = existingDoc.data()!;
        trusted = data['trusted'] as bool? ?? false;
        _dbg('[DEVICE] Existing device found, trusted=$trusted');
      } else {
        // New device - not trusted until approved
        trusted = false;
        _dbg('[DEVICE] New device, will require trust approval');
      }

      final device = DeviceInfo(
        deviceId: deviceId,
        deviceName: deviceName,
        publicKey: devicePublicKey,
        createdAt: existingDoc.exists
            ? (existingDoc.data()!['createdAt'] as Timestamp).toDate()
            : now,
        lastSeen: now,
        trusted: trusted,
        revoked: false,
        platform: platform,
        appVersion: appVersion,
      );

      // Store in Firestore under users/{uid}/devices/{deviceId}
      // Using merge: true makes this idempotent
      _dbg('[FIRESTORE] Writing device document: $deviceId');
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('devices')
          .doc(deviceId)
          .set(device.toFirestore(), SetOptions(merge: true));

      _dbg('[DEVICE] registerDevice: SUCCESS - deviceId=$deviceId, trusted=$trusted, newDevice=${!existingDoc.exists}');
    } catch (e) {
      _dbg('[DEVICE] registerDevice: ERROR - $e');
      _dbg('[FIRESTORE] Permission denied or other error');
      rethrow;
    }
  }

  /// Complete device registration with trust initialization
  /// 
  /// This should be called after registerDevice to initialize trust state
  /// and session management for the device.
  static Future<DeviceTrustState> completeDeviceRegistration(User user) async {
    _dbg('[DEVICE] completeDeviceRegistration: START - uid: ${user.uid}');

    try {
      // Initialize device trust
      _dbg('[TRUST] Initializing device trust...');
      final trustState = await DeviceTrustService.initializeTrust(user);
      _dbg('[TRUST] Trust status: ${trustState.status.name}');

      if (trustState.isTrusted) {
        // Device is trusted, initialize session
        _dbg('[DEVICE] Device trusted, initializing session');
        await SessionLifecycleManager.initializeSession(user);

        // Validate session integrity
        final valid = await SessionValidationService.validateSessionIntegrity(user);
        if (!valid) {
          _dbg('[DEVICE] Session validation failed');
        }
      } else {
        _dbg('[DEVICE] Device not yet trusted, deferring encryption');
      }

      return trustState;
    } catch (e) {
      _dbg('[DEVICE] completeDeviceRegistration: ERROR - $e');
      rethrow;
    }
  }

  /// Update last seen timestamp
  /// 
  /// Call periodically (e.g., every 5 minutes) while app is active
  static Future<void> updateLastSeen(User user) async {
    try {
      final deviceId = await getDeviceId();

      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('devices')
          .doc(deviceId)
          .update({
        'lastSeen': FieldValue.serverTimestamp(),
      });

      _dbg('updateLastSeen: updated for $deviceId');
    } catch (e) {
      _dbg('updateLastSeen: ERROR - $e');
      // Non-fatal, don't throw
    }
  }

  /// Revoke a device
  /// 
  /// When a device is revoked:
  /// - It can no longer receive encrypted messages
  /// - It remains in registry for audit purposes
  static Future<void> revokeDevice({
    required User user,
    required String deviceId,
  }) async {
    _dbg('revokeDevice: START - deviceId: $deviceId');

    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('devices')
          .doc(deviceId)
          .update({
        'revoked': true,
        'trusted': false,
        'revokedAt': FieldValue.serverTimestamp(),
      });

      _dbg('revokeDevice: SUCCESS - device revoked: $deviceId');
    } catch (e) {
      _dbg('revokeDevice: ERROR - $e');
      rethrow;
    }
  }

  /// Un-revoke a previously revoked device
  ///
  /// This allows a device to be trusted again after being revoked.
  /// Requires re-approval if there are other trusted devices.
  static Future<void> unrevokeDevice({
    required User user,
    required String deviceId,
  }) async {
    _dbg('unrevokeDevice: START - deviceId: $deviceId');

    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('devices')
          .doc(deviceId)
          .update({
        'revoked': false,
        'trusted': false, // Will require re-approval
        'unrevokedAt': FieldValue.serverTimestamp(),
      });

      _dbg('unrevokeDevice: SUCCESS - device unrevoked: $deviceId');
    } catch (e) {
      _dbg('unrevokeDevice: ERROR - $e');
      rethrow;
    }
  }

  /// Get all trusted devices for this user
  /// 
  /// Returns devices that:
  /// - Are not revoked
  /// - Have been seen in the last 30 days
  static Future<List<DeviceInfo>> getTrustedDevices(User user) async {
    _dbg('getTrustedDevices: START - uid: ${user.uid}');

    try {
      final thirtyDaysAgo = DateTime.now().subtract(const Duration(days: 30));

      final snapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('devices')
          .where('revoked', isEqualTo: false)
          .where('lastSeen', isGreaterThan: Timestamp.fromDate(thirtyDaysAgo))
          .get();

      final devices = snapshot.docs.map(DeviceInfo.fromFirestore).toList();

      _dbg('getTrustedDevices: SUCCESS - found ${devices.length} trusted devices');
      return devices;
    } catch (e) {
      _dbg('getTrustedDevices: ERROR - $e');
      return [];
    }
  }

  /// Get all devices (including revoked)
  /// 
  /// For device management UI
  static Future<List<DeviceInfo>> getAllDevices(User user) async {
    _dbg('getAllDevices: START - uid: ${user.uid}');

    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('devices')
          .orderBy('lastSeen', descending: true)
          .get();

      final devices = snapshot.docs.map(DeviceInfo.fromFirestore).toList();

      _dbg('getAllDevices: SUCCESS - found ${devices.length} devices');
      return devices;
    } catch (e) {
      _dbg('getAllDevices: ERROR - $e');
      return [];
    }
  }

  /// Check if current device is trusted
  /// 
  /// SECURITY: This uses DeviceTrustService for proper trust validation
  /// instead of directly checking Firestore. This ensures:
  /// 1. Trust state is properly cached
  /// 2. New devices are not silently auto-trusted
  /// 3. Revoked devices are properly blocked
  static Future<bool> isCurrentDeviceTrusted(User user) async {
    _dbg('isCurrentDeviceTrusted: START - uid: ${user.uid}');

    try {
      // Use DeviceTrustService for proper trust validation
      final trustState = await DeviceTrustService.getTrustState(user);
      final trusted = trustState.isTrusted;

      _dbg('isCurrentDeviceTrusted: result=$trusted');
      return trusted;
    } catch (e) {
      _dbg('isCurrentDeviceTrusted: ERROR - $e');
      return false;
    }
  }

  /// Request device approval
  /// 
  /// Called when a new device needs to be approved. Creates approval
  /// requests that existing trusted devices can approve.
  static Future<bool> requestDeviceApproval(User user) async {
    _dbg('requestDeviceApproval: START - uid: ${user.uid}');

    try {
      // Re-initialize trust which will create approval requests
      final trustState = await DeviceTrustService.initializeTrust(user);

      _dbg('requestDeviceApproval: status=${trustState.status.name}');
      return trustState.needsApproval;
    } catch (e) {
      _dbg('requestDeviceApproval: ERROR - $e');
      return false;
    }
  }

  /// Check for pending device approvals
  /// 
  /// Returns list of devices waiting for approval. Call this on existing
  /// devices to show approval UI when new devices try to join.
  static Future<List<Map<String, dynamic>>> getPendingApprovals(User user) async {
    return DeviceTrustService.getPendingApprovals(user);
  }

  /// Approve a device from this device
  /// 
  /// Called when user confirms a new device is theirs on an existing device.
  static Future<bool> approveDevice({
    required User user,
    required String deviceIdToApprove,
  }) async {
    _dbg('approveDevice: START - approving $deviceIdToApprove');

    try {
      // Verify current device is trusted before approving others
      if (!await isCurrentDeviceTrusted(user)) {
        _dbg('approveDevice: ERROR - current device not trusted');
        return false;
      }

      final result = await DeviceTrustService.approveDeviceFromExisting(
        user: user,
        deviceIdToApprove: deviceIdToApprove,
      );

      _dbg('approveDevice: result=$result');
      return result;
    } catch (e) {
      _dbg('approveDevice: ERROR - $e');
      return false;
    }
  }

  /// Reject a device approval
  static Future<bool> rejectDevice({
    required User user,
    required String deviceIdToReject,
    String? reason,
  }) async {
    _dbg('rejectDevice: START - rejecting $deviceIdToReject');

    try {
      // Verify current device is trusted
      if (!await isCurrentDeviceTrusted(user)) {
        _dbg('rejectDevice: ERROR - current device not trusted');
        return false;
      }

      final result = await DeviceTrustService.rejectDevice(
        user: user,
        deviceIdToReject: deviceIdToReject,
        reason: reason,
      );

      _dbg('rejectDevice: result=$result');
      return result;
    } catch (e) {
      _dbg('rejectDevice: ERROR - $e');
      return false;
    }
  }

  /// Handle session recovery and reconnect
  /// 
  /// Called when app comes back online or after long background period.
  /// Validates session and recovers from trusted devices if needed.
  static Future<RecoveryResult> recoverSession(User user) async {
    _dbg('recoverSession: START - uid: ${user.uid}');

    try {
      // Check and recover session
      final result = await SessionLifecycleManager.checkAndRecover(user);

      _dbg('recoverSession: state=${result.state.name}, success=${result.success}');
      return result;
    } catch (e) {
      _dbg('recoverSession: ERROR - $e');
      return RecoveryResult(
        success: false,
        state: SessionState.failed,
        message: 'Recovery failed: $e',
        timestamp: DateTime.now(),
      );
    }
  }

  /// Validate current session integrity
  /// 
  /// Should be called before sensitive operations
  static Future<bool> validateSession(User user) async {
    _dbg('validateSession: START - uid: ${user.uid}');

    try {
      // Validate device trust
      if (!await isCurrentDeviceTrusted(user)) {
        _dbg('validateSession: device not trusted');
        return false;
      }

      // Validate session integrity
      final valid = await SessionValidationService.validateSessionIntegrity(user);

      _dbg('validateSession: result=$valid');
      return valid;
    } catch (e) {
      _dbg('validateSession: ERROR - $e');
      return false;
    }
  }

  /// Delete device record (hard delete)
  ///
  /// Use with caution - prefer revokeDevice instead
  static Future<void> deleteDevice({
    required User user,
    required String deviceId,
  }) async {
    _dbg('deleteDevice: START - deviceId: $deviceId');

    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('devices')
          .doc(deviceId)
          .delete();

      // Also clean up session data
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('device_sessions')
          .doc(deviceId)
          .delete();

      _dbg('deleteDevice: SUCCESS - device deleted: $deviceId');
    } catch (e) {
      _dbg('deleteDevice: ERROR - $e');
      rethrow;
    }
  }

  /// Check if current device can revoke another device
  ///
  /// Security: Cannot revoke yourself
  static Future<bool> canRevokeDevice({
    required User user,
    required String deviceIdToRevoke,
  }) async {
    final currentDeviceId = await getDeviceId();
    return currentDeviceId != deviceIdToRevoke;
  }

  /// Reset device services on logout
  /// 
  /// Clears all cached state and resets services
  static Future<void> resetOnLogout() async {
    _dbg('resetOnLogout: START');

    await DeviceTrustService.reset();
    await SessionLifecycleManager.terminateSession();
    SessionValidationService.clearCache();

    _dbg('resetOnLogout: SUCCESS');
  }
}

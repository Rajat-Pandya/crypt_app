import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';

import 'device_service.dart';

/// Trust status for device approval flow
enum DeviceTrustStatus {
  trusted,    // Device is fully trusted and can access encrypted messages
  pending,    // Device is pending approval (new device)
  awaitingApproval, // Device approval request sent to existing devices
  rejected,   // Device was rejected by user
  revoked,    // Device was revoked by user
  failed,     // Trust check failed
}

/// Unified device trust state combining approval flow and encryption readiness.
///
/// This class consolidates two previously separate concepts:
/// 1. Device approval status (trust flow from device_trust_service.dart)
/// 2. Encryption readiness flags (key uploaded, encryption active from device_trust_state_manager.dart)
///
/// A device is "ready for encryption" when both [isTrusted] and [isKeyUploaded] are true.
class DeviceTrustState {
  // Approval flow state
  final DeviceTrustStatus status;
  final String deviceId;
  final String? otpCode;
  final DateTime? otpExpiresAt;
  final List<String>? pendingApprovals;
  final DateTime? requestedAt;
  final String? approvedBy;
  final DateTime? approvedAt;
  final String? rejectionReason;

  // Encryption readiness state
  final bool isKeyUploaded;
  final String? keyVersion;
  final bool isEncryptionActive;

  // Error state
  final bool hasError;
  final String? errorMessage;

  const DeviceTrustState({
    required this.status,
    required this.deviceId,
    this.otpCode,
    this.otpExpiresAt,
    this.pendingApprovals,
    this.requestedAt,
    this.approvedBy,
    this.approvedAt,
    this.rejectionReason,
    this.isKeyUploaded = false,
    this.keyVersion,
    this.isEncryptionActive = false,
    this.hasError = false,
    this.errorMessage,
  });

  // Derived properties
  bool get isTrusted => status == DeviceTrustStatus.trusted;
  bool get isPending => status == DeviceTrustStatus.pending;
  bool get isAwaitingApproval => status == DeviceTrustStatus.awaitingApproval;
  bool get needsApproval => isPending || isAwaitingApproval;
  bool get isRevoked => status == DeviceTrustStatus.revoked;
  bool get isRejected => status == DeviceTrustStatus.rejected;
  bool get isFailed => status == DeviceTrustStatus.failed;
  bool get isDevicePendingApproval => isPending || isAwaitingApproval;

  // Factory constructors
  static DeviceTrustState initial(String deviceId) => DeviceTrustState(
        status: DeviceTrustStatus.pending,
        deviceId: deviceId,
      );

  factory DeviceTrustState.trusted({
    required String deviceId,
    String? approvedBy,
    DateTime? approvedAt,
    String? keyVersion,
  }) {
    final isKeyUploaded = keyVersion != null;
    return DeviceTrustState(
      status: DeviceTrustStatus.trusted,
      deviceId: deviceId,
      approvedBy: approvedBy,
      approvedAt: approvedAt,
      isKeyUploaded: isKeyUploaded,
      keyVersion: keyVersion,
      isEncryptionActive: isKeyUploaded,
    );
  }

  factory DeviceTrustState.awaitingApproval({
    required String deviceId,
    required DateTime requestedAt,
    required List<String> pendingApprovals,
  }) => DeviceTrustState(
        status: DeviceTrustStatus.awaitingApproval,
        deviceId: deviceId,
        requestedAt: requestedAt,
        pendingApprovals: pendingApprovals,
      );

  factory DeviceTrustState.revoked({required String deviceId}) => DeviceTrustState(
        status: DeviceTrustStatus.revoked,
        deviceId: deviceId,
      );

  factory DeviceTrustState.failed({
    required String deviceId,
    required String errorMessage,
  }) => DeviceTrustState(
        status: DeviceTrustStatus.failed,
        deviceId: deviceId,
        hasError: true,
        errorMessage: errorMessage,
      );

  // Copy with modifications
  DeviceTrustState copyWith({
    DeviceTrustStatus? status,
    String? deviceId,
    String? otpCode,
    DateTime? otpExpiresAt,
    List<String>? pendingApprovals,
    DateTime? requestedAt,
    String? approvedBy,
    DateTime? approvedAt,
    String? rejectionReason,
    bool? isKeyUploaded,
    String? keyVersion,
    bool? isEncryptionActive,
    bool? hasError,
    String? errorMessage,
    bool clearOtpCode = false,
    bool clearOtpExpiresAt = false,
    bool clearPendingApprovals = false,
    bool clearRequestedAt = false,
    bool clearApprovedBy = false,
    bool clearApprovedAt = false,
    bool clearRejectionReason = false,
    bool clearKeyVersion = false,
    bool clearErrorMessage = false,
  }) => DeviceTrustState(
        status: status ?? this.status,
        deviceId: deviceId ?? this.deviceId,
        otpCode: clearOtpCode ? null : (otpCode ?? this.otpCode),
        otpExpiresAt: clearOtpExpiresAt ? null : (otpExpiresAt ?? this.otpExpiresAt),
        pendingApprovals: clearPendingApprovals ? null : (pendingApprovals ?? this.pendingApprovals),
        requestedAt: clearRequestedAt ? null : (requestedAt ?? this.requestedAt),
        approvedBy: clearApprovedBy ? null : (approvedBy ?? this.approvedBy),
        approvedAt: clearApprovedAt ? null : (approvedAt ?? this.approvedAt),
        rejectionReason: clearRejectionReason ? null : (rejectionReason ?? this.rejectionReason),
        isKeyUploaded: isKeyUploaded ?? this.isKeyUploaded,
        keyVersion: clearKeyVersion ? null : (keyVersion ?? this.keyVersion),
        isEncryptionActive: isEncryptionActive ?? this.isEncryptionActive,
        hasError: hasError ?? this.hasError,
        errorMessage: clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      );

  // Serialization
  Map<String, dynamic> toMap() => {
        'status': status.name,
        'deviceId': deviceId,
        'otpCode': otpCode,
        'otpExpiresAt': otpExpiresAt?.millisecondsSinceEpoch,
        'pendingApprovals': pendingApprovals,
        'requestedAt': requestedAt?.millisecondsSinceEpoch,
        'approvedBy': approvedBy,
        'approvedAt': approvedAt?.millisecondsSinceEpoch,
        'rejectionReason': rejectionReason,
        'isKeyUploaded': isKeyUploaded,
        'keyVersion': keyVersion,
        'isEncryptionActive': isEncryptionActive,
        'hasError': hasError,
        'errorMessage': errorMessage,
      };

  static DeviceTrustState fromMap(Map<String, dynamic> map) => DeviceTrustState(
        status: DeviceTrustStatus.values.byName(map['status'] as String),
        deviceId: map['deviceId'] as String,
        otpCode: map['otpCode'] as String?,
        otpExpiresAt: map['otpExpiresAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(map['otpExpiresAt'] as int)
            : null,
        pendingApprovals: (map['pendingApprovals'] as List<dynamic>?)?.cast<String>(),
        requestedAt: map['requestedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(map['requestedAt'] as int)
            : null,
        approvedBy: map['approvedBy'] as String?,
        approvedAt: map['approvedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(map['approvedAt'] as int)
            : null,
        rejectionReason: map['rejectionReason'] as String?,
        isKeyUploaded: map['isKeyUploaded'] as bool? ?? false,
        keyVersion: map['keyVersion'] as String?,
        isEncryptionActive: map['isEncryptionActive'] as bool? ?? false,
        hasError: map['hasError'] as bool? ?? false,
        errorMessage: map['errorMessage'] as String?,
      );

  @override
  String toString() =>
      'DeviceTrustState(status: ${status.name}, deviceId: $deviceId, '
      'isTrusted: $isTrusted, isKeyUploaded: $isKeyUploaded, '
      'isEncryptionActive: $isEncryptionActive, keyVersion: $keyVersion, '
      'needsApproval: $needsApproval, hasError: $hasError)';
}

/// Unified device trust manager combining approval flow, OTP generation,
/// and encryption readiness management.
///
/// This static class consolidates functionality from:
/// - DeviceTrustService: Trust approval flow, OTP generation, device approval/rejection
/// - DeviceTrustStateManager: Trust state management, streams
///
/// CRITICAL SECURITY PRINCIPLES:
/// 1. New devices MUST be approved - no silent auto-trust
/// 2. Two approval methods: OTP (backup code) or existing device approval
/// 3. Trust state is stored in Firestore and cached locally
/// 4. Private keys are NOT accessible until device is trusted
/// 5. All trust changes are logged with timestamps
class DeviceTrustManager {
  // Instance
  static final DeviceTrustManager _instance = DeviceTrustManager._internal();
  factory DeviceTrustManager() => _instance;
  DeviceTrustManager._internal();

  // Dependencies
  static final _firestore = FirebaseFirestore.instance;
  static const _storage = FlutterSecureStorage();

  // Configuration
  static const Duration _otpValidity = Duration(minutes: 10);
  static const Duration _approvalTimeout = Duration(minutes: 5);
  static const String _trustStateKey = 'device_trust_state';
  static const String _privateKeyStorageKey = 'private_key';

  // State
  static DeviceTrustState? _cachedState;
  static final _stateController = StreamController<DeviceTrustState>.broadcast();
  static StreamSubscription<DeviceTrustState>? _globalTrustSubscription;
  static DeviceTrustState? _lastEmittedState;
  static DateTime? _lastEmissionTime;
  static const Duration _minEmissionInterval = Duration(milliseconds: 100);

  // ==========================================================================
  // PUBLIC API - STREAMS & STATE ACCESS
  // ==========================================================================

  /// Stream of trust state changes
  static Stream<DeviceTrustState> get stateStream => _stateController.stream;

  /// Current cached trust state (null if not loaded)
  static DeviceTrustState? get currentState => _cachedState;

  /// Check if encryption is active for current device
  static bool get isEncryptionActive => _cachedState?.isEncryptionActive ?? false;
  
  /// Check if key is uploaded
  static bool get isKeyUploaded => _cachedState?.isKeyUploaded ?? false;
  
  /// Check if device is pending approval
  static bool get isDevicePendingApproval => _cachedState?.isDevicePendingApproval ?? false;

  // ==========================================================================
  // PUBLIC API - STATE QUERIES
  // ==========================================================================

  /// Check if current device is trusted
  static Future<bool> isTrusted(User user) async {
    try {
      return (await getTrustState(user)).isTrusted;
    } catch (e) {
      _dbg('isTrusted: ERROR - $e');
      return false;
    }
  }

  /// Get current device trust state
  static Future<DeviceTrustState> getTrustState(User user) async {
    // Check memory cache first
    if (_cachedState != null) return _cachedState!;

    // Check local storage cache
    try {
      final cached = await _storage.read(key: _trustStateKey);
      if (cached != null) {
        _cachedState = DeviceTrustState.fromMap(jsonDecode(cached) as Map<String, dynamic>);
        return _cachedState!;
      }
    } catch (e) {
      _dbg('getTrustState: cache read error - $e');
    }

    // Fetch from Firestore
    return _fetchFromFirestore(user);
  }

  // ==========================================================================
  // PUBLIC API - TRUST INITIALIZATION
  // ==========================================================================

  /// Initialize trust for new device. First device is auto-trusted.
  static Future<DeviceTrustState> initializeTrust(User user) async {
    _dbg('initializeTrust: START - uid: ${user.uid}');

    try {
      final deviceId = await DeviceService.getDeviceId();
      final existingDevices = await _getExistingTrustedDevices(user);
      _dbg('initializeTrust: found ${existingDevices.length} existing trusted devices');

      // First device auto-trusts; subsequent devices need approval
      if (existingDevices.isEmpty) {
        return _autoTrustFirstDevice(user, deviceId);
      }
      return _checkExistingDeviceStatus(user, deviceId, existingDevices);
    } catch (e) {
      _dbg('initializeTrust: ERROR - $e');
      final deviceId = await DeviceService.getDeviceId();
      final state = DeviceTrustState.failed(deviceId: deviceId, errorMessage: e.toString());
      _emitState(state);
      return state;
    }
  }

  // ==========================================================================
  // PUBLIC API - OTP
  // ==========================================================================

  /// Generate OTP for backup device approval. Returns 6-digit code or null.
  static Future<String?> generateOTP(User user) async {
    try {
      final otp = _generateSecureOTP();
      final expiresAt = DateTime.now().add(_otpValidity);
      final salt = _generateSalt();
      final hash = _hashOTPWithSalt(otp, salt);

      await _firestore
          .collection('users').doc(user.uid).collection('device_otps').doc('current')
          .set({
        'codeHash': hash,
        'codeSalt': base64Encode(salt),
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(expiresAt),
        'used': false,
        'deviceId': await DeviceService.getDeviceId(),
      });

      _dbg('generateOTP: SUCCESS - OTP generated, expires at $expiresAt');
      return otp;
    } catch (e) {
      _dbg('generateOTP: ERROR - $e');
      return null;
    }
  }

  /// Validate OTP and approve device.
  static Future<bool> validateOTP({required User user, required String otp}) async {
    try {
      final doc = await _firestore
          .collection('users').doc(user.uid).collection('device_otps').doc('current')
          .get();

      if (!doc.exists) return false;
      
      final data = doc.data()!;
      if (data['used'] as bool? ?? false) return false;
      if (DateTime.now().isAfter((data['expiresAt'] as Timestamp).toDate())) return false;

      final salt = base64Decode(data['codeSalt'] as String);
      final computedHash = _hashOTPWithSalt(otp, salt);
      if (!_constantTimeEquals(computedHash, data['codeHash'] as String)) return false;

      await doc.reference.update({'used': true});
      await _approveDevice(
        user: user,
        deviceId: await DeviceService.getDeviceId(),
        approvedBy: 'otp',
      );
      return true;
    } catch (e) {
      _dbg('validateOTP: ERROR - $e');
      return false;
    }
  }

  // ==========================================================================
  // PUBLIC API - DEVICE APPROVAL/REJECTION
  // ==========================================================================

  /// Approve a device from an existing trusted device.
  static Future<bool> approveDeviceFromExisting({
    required User user,
    required String deviceIdToApprove,
  }) async {
    try {
      if (!await isTrusted(user)) {
        _dbg('approveDeviceFromExisting: current device not trusted');
        return false;
      }
      await _approveDevice(
        user: user,
        deviceId: deviceIdToApprove,
        approvedBy: await DeviceService.getDeviceId(),
      );
      return true;
    } catch (e) {
      _dbg('approveDeviceFromExisting: ERROR - $e');
      return false;
    }
  }

  /// Reject a device approval request.
  static Future<bool> rejectDevice({
    required User user,
    required String deviceIdToReject,
    String? reason,
  }) async {
    try {
      await _firestore
          .collection('users').doc(user.uid).collection('devices').doc(deviceIdToReject)
          .update({
        'trusted': false,
        'rejectedAt': FieldValue.serverTimestamp(),
        'rejectionReason': reason ?? 'rejected_by_user',
      });
      return true;
    } catch (e) {
      _dbg('rejectDevice: ERROR - $e');
      return false;
    }
  }

  // ==========================================================================
  // PUBLIC API - ENCRYPTION STATE MANAGEMENT
  // ==========================================================================

  /// Mark key as uploaded. Automatically activates encryption if device is trusted.
  static void markKeyUploaded(String keyVersion) {
    if (_cachedState == null) return;
    final newState = _cachedState!.copyWith(isKeyUploaded: true, keyVersion: keyVersion);
    _cachedState = newState.copyWith(
      isEncryptionActive: newState.isKeyUploaded && newState.isTrusted,
    );
    _emitAndPersist(_cachedState!);
  }

  /// Mark device as trusted. Automatically activates encryption if key is uploaded.
  static void markDeviceTrusted() {
    if (_cachedState == null) return;
    _cachedState = _cachedState!.copyWith(
      status: DeviceTrustStatus.trusted,
    ).copyWith(
      clearRequestedAt: true,
      clearPendingApprovals: true,
      isEncryptionActive: _cachedState!.isKeyUploaded,
    );
    _emitAndPersist(_cachedState!);
  }

  /// Mark encryption as active (only if both conditions met).
  static void markEncryptionActive() {
    if (_cachedState == null) return;
    if (_cachedState!.isKeyUploaded && _cachedState!.isTrusted) {
      _cachedState = _cachedState!.copyWith(isEncryptionActive: true);
      _emitAndPersist(_cachedState!);
    }
  }

  /// Set key version (fingerprint).
  static void setKeyVersion(String version) {
    if (_cachedState == null) return;
    _cachedState = _cachedState!.copyWith(keyVersion: version);
    _emitAndPersist(_cachedState!);
  }

  /// Mark device as pending approval.
  static void markDevicePendingApproval() {
    if (_cachedState == null) return;
    _cachedState = _cachedState!.copyWith(
      status: DeviceTrustStatus.awaitingApproval,
      isEncryptionActive: false,
    );
    _emitAndPersist(_cachedState!);
  }

  // ==========================================================================
  // PUBLIC API - STREAM LISTENERS
  // ==========================================================================

  /// Listen for trust state changes from Firestore.
  static Stream<DeviceTrustState> listenToTrustChanges(User user) {
    return Stream.fromFuture(DeviceService.getDeviceId()).asyncExpand((deviceId) {
      return _firestore
          .collection('users').doc(user.uid).collection('devices').doc(deviceId)
          .snapshots()
          .asyncMap((doc) async {
        if (!doc.exists) {
          return DeviceTrustState.initial(await DeviceService.getDeviceId());
        }
        final data = doc.data()!;
        final trusted = data['trusted'] as bool? ?? false;
        final revoked = data['revoked'] as bool? ?? false;
        
        final DeviceTrustStatus status;
        if (revoked) {
          status = DeviceTrustStatus.revoked;
        } else if (trusted) {
          status = DeviceTrustStatus.trusted;
        } else {
          status = DeviceTrustStatus.pending;
        }

        return DeviceTrustState(
          status: status,
          deviceId: doc.id,
          approvedBy: data['approvedBy'] as String?,
          approvedAt: data['approvedAt'] != null ? (data['approvedAt'] as Timestamp).toDate() : null,
          rejectionReason: data['rejectionReason'] as String?,
        );
      });
    });
  }

  /// Start global listener for real-time trust state changes.
  static void startGlobalListener(User user) {
    stopGlobalListener();
    _globalTrustSubscription = listenToTrustChanges(user).listen(
      (state) async {
        _cachedState = state;
        await _persistState(state);
        _emitState(state);
        if (state.status == DeviceTrustStatus.revoked) {
          await _storage.delete(key: _trustStateKey);
        }
      },
      onError: (e) => _dbg('Global trust listener error: $e'),
    );
  }

  /// Stop the global trust state listener.
  static void stopGlobalListener() {
    _globalTrustSubscription?.cancel();
    _globalTrustSubscription = null;
  }

  // ==========================================================================
  // PUBLIC API - PENDING APPROVALS
  // ==========================================================================

  /// Get pending approval requests for this user.
  static Future<List<Map<String, dynamic>>> getPendingApprovals(User user) async {
    try {
      final snapshot = await _firestore
          .collection('users').doc(user.uid).collection('devices')
          .where('trusted', isEqualTo: false)
          .where('revoked', isEqualTo: false)
          .where('trustRequestedAt', isGreaterThan: Timestamp.fromDate(
            DateTime.now().subtract(const Duration(hours: 24)),
          ))
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'deviceId': doc.id,
          'deviceName': data['deviceName'] ?? 'Unknown Device',
          'platform': data['platform'] ?? 'unknown',
          'requestedAt': data['trustRequestedAt'],
        };
      }).toList();
    } catch (e) {
      _dbg('getPendingApprovals: ERROR - $e');
      return [];
    }
  }

  // ==========================================================================
  // PUBLIC API - CLEANUP
  // ==========================================================================

  /// Clear cache and reset state on logout.
  static Future<void> reset() async {
    stopGlobalListener();
    _cachedState = null;
    _lastEmittedState = null;
    _lastEmissionTime = null;
    await _storage.delete(key: _trustStateKey);
  }

  // ==========================================================================
  // PRIVATE METHODS - STATE MANAGEMENT
  // ==========================================================================

  static void _emitState(DeviceTrustState state) {
    final now = DateTime.now();
    if (_lastEmittedState != null && 
        _lastEmittedState!.status == state.status &&
        _lastEmittedState!.deviceId == state.deviceId &&
        _lastEmittedState!.isEncryptionActive == state.isEncryptionActive) {
      if (_lastEmissionTime != null &&
          now.difference(_lastEmissionTime!) < _minEmissionInterval) {
        return;
      }
    }
    _lastEmittedState = state;
    _lastEmissionTime = now;
    _stateController.add(state);
  }

  static Future<void> _persistState(DeviceTrustState state) async {
    try {
      await _storage.write(key: _trustStateKey, value: jsonEncode(state.toMap()));
    } catch (e) {
      _dbg('_persistState: ERROR - $e');
    }
  }

  static void _emitAndPersist(DeviceTrustState state) {
    _emitState(state);
    _persistState(state);
  }

  // ==========================================================================
  // PRIVATE METHODS - FIRESTORE OPERATIONS
  // ==========================================================================

  static Future<DeviceTrustState> _fetchFromFirestore(User user) async {
    try {
      final deviceId = await DeviceService.getDeviceId();
      final doc = await _firestore
          .collection('users').doc(user.uid).collection('devices').doc(deviceId)
          .get();

      if (!doc.exists) {
        _cachedState = DeviceTrustState.initial(deviceId);
        return _cachedState!;
      }

      final data = doc.data()!;
      final trusted = data['trusted'] as bool? ?? false;
      final revoked = data['revoked'] as bool? ?? false;
      
      final DeviceTrustStatus status;
      if (revoked) {
        status = DeviceTrustStatus.revoked;
      } else if (trusted) {
        status = DeviceTrustStatus.trusted;
      } else {
        status = DeviceTrustStatus.pending;
      }

      _cachedState = DeviceTrustState(
        status: status,
        deviceId: deviceId,
        requestedAt: data['trustRequestedAt'] != null ? (data['trustRequestedAt'] as Timestamp).toDate() : null,
        approvedBy: data['approvedBy'] as String?,
        approvedAt: data['approvedAt'] != null ? (data['approvedAt'] as Timestamp).toDate() : null,
        rejectionReason: data['rejectionReason'] as String?,
      );
      await _persistState(_cachedState!);
      return _cachedState!;
    } catch (e) {
      final deviceId = await DeviceService.getDeviceId();
      return DeviceTrustState.failed(deviceId: deviceId, errorMessage: e.toString());
    }
  }

  static Future<List<Map<String, dynamic>>> _getExistingTrustedDevices(User user) async {
    try {
      final snapshot = await _firestore
          .collection('users').doc(user.uid).collection('devices')
          .where('trusted', isEqualTo: true)
          .where('revoked', isEqualTo: false)
          .get();
      return snapshot.docs.map((doc) => {'deviceId': doc.id, ...doc.data()}).toList();
    } catch (e) {
      _dbg('_getExistingTrustedDevices: ERROR - $e');
      return [];
    }
  }

  // ==========================================================================
  // PRIVATE METHODS - TRUST INITIALIZATION
  // ==========================================================================

  static Future<DeviceTrustState> _autoTrustFirstDevice(User user, String deviceId) async {
    final deviceDoc = await _firestore
        .collection('users').doc(user.uid).collection('devices').doc(deviceId)
        .get();
        
    if (!deviceDoc.exists) {
      await _registerDeviceAsTrusted(user: user, deviceId: deviceId, approvedBy: 'system_auto_first_device');
    } else {
      await _firestore
          .collection('users').doc(user.uid).collection('devices').doc(deviceId)
          .update({
        'trusted': true,
        'approvedBy': 'system_auto_first_device',
        'approvedAt': FieldValue.serverTimestamp(),
        'trustRequestPending': false,
      });
    }
    
    final keyVersion = await _checkLocalKeyExists() ? 'local_v1' : null;
    final state = DeviceTrustState.trusted(
      deviceId: deviceId,
      approvedBy: 'system_auto_first_device',
      approvedAt: DateTime.now(),
      keyVersion: keyVersion,
    );
    
    _cachedState = state;
    await _persistState(state);
    _emitState(state);
    return state;
  }

  static Future<DeviceTrustState> _checkExistingDeviceStatus(
    User user,
    String deviceId,
    List<Map<String, dynamic>> existingDevices,
  ) async {
    final doc = await _firestore
        .collection('users').doc(user.uid).collection('devices').doc(deviceId)
        .get();

    if (doc.exists) {
      final data = doc.data()!;
      final trusted = data['trusted'] as bool? ?? false;
      final revoked = data['revoked'] as bool? ?? false;

      if (trusted && !revoked) {
        final keyVersion = await _checkLocalKeyExists() ? 'local_v1' : null;
        final state = DeviceTrustState.trusted(
          deviceId: deviceId,
          approvedBy: data['approvedBy'] as String?,
          approvedAt: data['approvedAt'] != null ? (data['approvedAt'] as Timestamp).toDate() : null,
          keyVersion: keyVersion,
        );
        _cachedState = state;
        await _persistState(state);
        _emitState(state);
        return state;
      }

      if (revoked) {
        final state = DeviceTrustState.revoked(deviceId: deviceId);
        _cachedState = state;
        await _persistState(state);
        _emitState(state);
        return state;
      }
    }

    return _createTrustRequest(user: user, deviceId: deviceId, existingDevices: existingDevices);
  }

  static Future<void> _registerDeviceAsTrusted({
    required User user,
    required String deviceId,
    required String approvedBy,
  }) async {
    await _firestore
        .collection('users').doc(user.uid).collection('devices').doc(deviceId)
        .set({
      'deviceId': deviceId,
      'platform': 'flutter',
      'trusted': true,
      'approvedBy': approvedBy,
      'approvedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
      'trustRequestPending': false,
      'revoked': false,
    });
  }

  static Future<DeviceTrustState> _createTrustRequest({
    required User user,
    required String deviceId,
    required List<Map<String, dynamic>> existingDevices,
  }) async {
    final requestedAt = DateTime.now();

    await _firestore
        .collection('users').doc(user.uid).collection('devices').doc(deviceId)
        .set({
      'trusted': false,
      'trustRequestedAt': FieldValue.serverTimestamp(),
      'trustRequestPending': true,
    }, SetOptions(merge: true));

    for (final device in existingDevices) {
      await _firestore
          .collection('users').doc(user.uid).collection('device_approvals')
          .add({
        'targetDeviceId': deviceId,
        'approverDeviceId': device['deviceId'],
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(requestedAt.add(_approvalTimeout)),
      });
    }

    final state = DeviceTrustState.awaitingApproval(
      deviceId: deviceId,
      requestedAt: requestedAt,
      pendingApprovals: existingDevices.map((d) => d['deviceId'] as String).toList(),
    );

    _cachedState = state;
    await _persistState(state);
    _emitState(state);
    return state;
  }

  static Future<DeviceTrustState> _approveDevice({
    required User user,
    required String deviceId,
    required String approvedBy,
  }) async {
    await _firestore
        .collection('users').doc(user.uid).collection('devices').doc(deviceId)
        .update({
      'trusted': true,
      'trustRequestPending': false,
      'approvedBy': approvedBy,
      'approvedAt': FieldValue.serverTimestamp(),
    });

    final pendingApprovals = await _firestore
        .collection('users').doc(user.uid).collection('device_approvals')
        .where('targetDeviceId', isEqualTo: deviceId)
        .where('status', isEqualTo: 'pending')
        .get();

    for (final doc in pendingApprovals.docs) {
      await doc.reference.update({
        'status': 'completed',
        'completedAt': FieldValue.serverTimestamp(),
      });
    }

    final keyVersion = await _checkLocalKeyExists() ? 'local_v1' : null;
    final state = DeviceTrustState.trusted(
      deviceId: deviceId,
      approvedBy: approvedBy,
      approvedAt: DateTime.now(),
      keyVersion: keyVersion,
    );

    _cachedState = state;
    await _persistState(state);
    return state;
  }

  // ==========================================================================
  // PRIVATE METHODS - CRYPTOGRAPHY
  // ==========================================================================

  static String _generateSecureOTP() {
    final random = Random.secure();
    return List.generate(6, (_) => random.nextInt(10)).join();
  }

  static String _hashOTPWithSalt(String otp, List<int> salt) {
    final password = List<int>.from(utf8.encode(otp));
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    final params = Pbkdf2Parameters(Uint8List.fromList(salt), 100000, 32);
    pbkdf2.init(params);
    final derivedKey = pbkdf2.process(Uint8List.fromList(password));
    return base64Encode(derivedKey);
  }
  
  static List<int> _generateSalt() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256));
  }
  
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }

  // ==========================================================================
  // PRIVATE METHODS - UTILITY
  // ==========================================================================

  static Future<bool> _checkLocalKeyExists() async {
    try {
      final privateKey = await _storage.read(key: _privateKeyStorageKey);
      return privateKey != null && privateKey.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  static void _dbg(String message) {
    assert(() {
      debugPrint('[TRUST_MANAGER] $message');
      return true;
    }());
  }
}

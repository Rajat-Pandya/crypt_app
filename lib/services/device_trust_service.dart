import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';

import 'device_trust_manager.dart' as dtm;

/// DEPRECATED: Use DeviceTrustStatus from DeviceTrustManager.
@Deprecated('Use DeviceTrustStatus from DeviceTrustManager.')
enum DeviceTrustStatus {
  trusted,
  pending,
  awaitingApproval,
  rejected,
  revoked,
  failed,
}

/// DEPRECATED: Use DeviceTrustState from DeviceTrustManager.
/// 
/// This is the old approval-flow focused state. The new DeviceTrustState
/// includes both approval flow AND encryption readiness flags.
@Deprecated('Use DeviceTrustState from DeviceTrustManager.')
class DeviceTrustState {
  final DeviceTrustStatus status;
  final String deviceId;
  final String? otpCode;
  final DateTime? otpExpiresAt;
  final List<String>? pendingApprovals;
  final DateTime? requestedAt;
  final String? approvedBy;
  final DateTime? approvedAt;
  final String? rejectionReason;

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
  });

  bool get isTrusted => status == DeviceTrustStatus.trusted;
  bool get isPending => status == DeviceTrustStatus.pending;
  bool get isAwaitingApproval => status == DeviceTrustStatus.awaitingApproval;
  bool get needsApproval => isPending || isAwaitingApproval;

  factory DeviceTrustState._fromNew(dtm.DeviceTrustState newState) {
    return DeviceTrustState(
      status: _mapStatus(newState.status),
      deviceId: newState.deviceId,
      otpCode: newState.otpCode,
      otpExpiresAt: newState.otpExpiresAt,
      pendingApprovals: newState.pendingApprovals,
      requestedAt: newState.requestedAt,
      approvedBy: newState.approvedBy,
      approvedAt: newState.approvedAt,
      rejectionReason: newState.rejectionReason,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'status': status.name,
      'deviceId': deviceId,
      'otpCode': otpCode,
      'otpExpiresAt': otpExpiresAt?.millisecondsSinceEpoch,
      'pendingApprovals': pendingApprovals,
      'requestedAt': requestedAt?.millisecondsSinceEpoch,
      'approvedBy': approvedBy,
      'approvedAt': approvedAt?.millisecondsSinceEpoch,
      'rejectionReason': rejectionReason,
    };
  }

  static DeviceTrustState fromMap(Map<String, dynamic> map) {
    return DeviceTrustState(
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
    );
  }
}

/// DEPRECATED: Use DeviceTrustManager instead.
/// 
/// All methods delegate to DeviceTrustManager.
@Deprecated('Use DeviceTrustManager instead.')
class DeviceTrustService {
  static final DeviceTrustService _instance = DeviceTrustService._internal();
  factory DeviceTrustService() => _instance;
  DeviceTrustService._internal();

  static Stream<DeviceTrustState> get stateStream => 
      dtm.DeviceTrustManager.stateStream.map(DeviceTrustState._fromNew);

  static DeviceTrustState? get currentState {
    final state = dtm.DeviceTrustManager.currentState;
    return state != null ? DeviceTrustState._fromNew(state) : null;
  }

  static Future<bool> isTrusted(User user) async {
    return await dtm.DeviceTrustManager.isTrusted(user);
  }

  static Future<DeviceTrustState> getTrustState(User user) async {
    final state = await dtm.DeviceTrustManager.getTrustState(user);
    return DeviceTrustState._fromNew(state);
  }

  static Future<String?> generateOTP(User user) async {
    return await dtm.DeviceTrustManager.generateOTP(user);
  }

  static Future<bool> validateOTP({required User user, required String otp}) async {
    return await dtm.DeviceTrustManager.validateOTP(user: user, otp: otp);
  }

  static Future<bool> approveDeviceFromExisting({
    required User user,
    required String deviceIdToApprove,
  }) async {
    return await dtm.DeviceTrustManager.approveDeviceFromExisting(
      user: user,
      deviceIdToApprove: deviceIdToApprove,
    );
  }

  static Future<bool> rejectDevice({
    required User user,
    required String deviceIdToReject,
    String? reason,
  }) async {
    return await dtm.DeviceTrustManager.rejectDevice(
      user: user,
      deviceIdToReject: deviceIdToReject,
      reason: reason,
    );
  }

  static Future<DeviceTrustState> initializeTrust(User user) async {
    final state = await dtm.DeviceTrustManager.initializeTrust(user);
    return DeviceTrustState._fromNew(state);
  }

  static Future<List<Map<String, dynamic>>> getPendingApprovals(User user) async {
    return await dtm.DeviceTrustManager.getPendingApprovals(user);
  }

  static Future<void> initializeDeviceTrust(User user) async {
    await dtm.DeviceTrustManager.initializeTrust(user);
  }

  static Stream<DeviceTrustState> listenToTrustChanges(User user) {
    return dtm.DeviceTrustManager.listenToTrustChanges(user).map(DeviceTrustState._fromNew);
  }

  static void startGlobalListener(User user) {
    dtm.DeviceTrustManager.startGlobalListener(user);
  }

  static void stopListening() {
    dtm.DeviceTrustManager.stopGlobalListener();
  }

  static Future<void> reset() async {
    await dtm.DeviceTrustManager.reset();
  }
}

DeviceTrustStatus _mapStatus(dtm.DeviceTrustStatus status) {
  switch (status) {
    case dtm.DeviceTrustStatus.trusted: return DeviceTrustStatus.trusted;
    case dtm.DeviceTrustStatus.pending: return DeviceTrustStatus.pending;
    case dtm.DeviceTrustStatus.awaitingApproval: return DeviceTrustStatus.awaitingApproval;
    case dtm.DeviceTrustStatus.rejected: return DeviceTrustStatus.rejected;
    case dtm.DeviceTrustStatus.revoked: return DeviceTrustStatus.revoked;
    case dtm.DeviceTrustStatus.failed: return DeviceTrustStatus.failed;
  }
}

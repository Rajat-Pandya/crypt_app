import 'dart:async';

import 'device_trust_manager.dart' as dtm;

/// DEPRECATED: Use DeviceTrustState from DeviceTrustManager.
/// 
/// This class is kept for backward compatibility.
/// The new unified DeviceTrustState includes both encryption flags AND approval flow state.
@Deprecated('Use DeviceTrustState from DeviceTrustManager.')
class DeviceTrustState {
  final bool isKeyUploaded;
  final bool isDeviceTrusted;
  final bool isEncryptionActive;
  final String? keyVersion;
  final bool isDevicePendingApproval;
  final bool hasError;
  final String? errorMessage;

  const DeviceTrustState({
    this.isKeyUploaded = false,
    this.isDeviceTrusted = false,
    this.isEncryptionActive = false,
    this.keyVersion,
    this.isDevicePendingApproval = false,
    this.hasError = false,
    this.errorMessage,
  });

  static const DeviceTrustState initial = DeviceTrustState();

  DeviceTrustState copyWith({
    bool? isKeyUploaded,
    bool? isDeviceTrusted,
    bool? isEncryptionActive,
    String? keyVersion,
    bool? isDevicePendingApproval,
    bool? hasError,
    String? errorMessage,
  }) {
    return DeviceTrustState(
      isKeyUploaded: isKeyUploaded ?? this.isKeyUploaded,
      isDeviceTrusted: isDeviceTrusted ?? this.isDeviceTrusted,
      isEncryptionActive: isEncryptionActive ?? this.isEncryptionActive,
      keyVersion: keyVersion ?? this.keyVersion,
      isDevicePendingApproval: isDevicePendingApproval ?? this.isDevicePendingApproval,
      hasError: hasError ?? this.hasError,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  /// Convert from new unified state
  factory DeviceTrustState._fromNew(dtm.DeviceTrustState newState) {
    return DeviceTrustState(
      isKeyUploaded: newState.isKeyUploaded,
      isDeviceTrusted: newState.isTrusted,
      isEncryptionActive: newState.isEncryptionActive,
      keyVersion: newState.keyVersion,
      isDevicePendingApproval: newState.status == dtm.DeviceTrustStatus.pending ||
          newState.status == dtm.DeviceTrustStatus.awaitingApproval,
      hasError: newState.hasError,
      errorMessage: newState.errorMessage,
    );
  }
}

/// DEPRECATED: Use DeviceTrustManager instead.
/// 
/// All methods delegate to DeviceTrustManager.
@Deprecated('Use DeviceTrustManager instead.')
class DeviceTrustStateManager {
  static Stream<DeviceTrustState> get stateStream => 
      dtm.DeviceTrustManager.stateStream.map(DeviceTrustState._fromNew);

  static DeviceTrustState get currentState => 
      DeviceTrustState._fromNew(dtm.DeviceTrustManager.currentState ?? 
        dtm.DeviceTrustState.initial('unknown'));

  static void markKeyUploaded(String keyVersion) {
    dtm.DeviceTrustManager.markKeyUploaded(keyVersion);
  }

  static void markDeviceTrusted() {
    dtm.DeviceTrustManager.markDeviceTrusted();
  }

  static void markEncryptionActive() {
    dtm.DeviceTrustManager.markEncryptionActive();
  }

  static void setKeyVersion(String keyVersion) {
    dtm.DeviceTrustManager.setKeyVersion(keyVersion);
  }

  static void markDevicePendingApproval() {
    dtm.DeviceTrustManager.markDevicePendingApproval();
  }

  static Future<void> reset() async {
    await dtm.DeviceTrustManager.reset();
  }
}

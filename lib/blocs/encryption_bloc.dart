import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/asymmetric/pkcs1.dart';
import 'package:pointycastle/asymmetric/rsa.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';


import '../services/crypto_security_service.dart';
import '../services/encryption_lifecycle.dart';
import '../services/hmac_key_service.dart';
import '../utils/encryption.dart';
import '../utils/rsa_helper.dart';

// Export SessionRecommendation from security service
export '../services/crypto_security_service.dart' show SessionRecommendation;

// ============================================================================
// EVENTS (Extended with Security Events)
// ============================================================================

/// Base class for all encryption events
abstract class EncryptionEvent {
  const EncryptionEvent();
}

/// Initialize encryption system
class EncryptionInitialized extends EncryptionEvent {
  final String currentUserId;
  final String receiverId;
  
  const EncryptionInitialized({
    required this.currentUserId,
    required this.receiverId,
  });
}

/// Load encryption keys for current user
class LoadEncryptionKeys extends EncryptionEvent {
  final bool forceRefresh;
  
  const LoadEncryptionKeys({this.forceRefresh = false});
}

/// Load receiver's public key
class LoadReceiverPublicKey extends EncryptionEvent {
  final String receiverId;
  final bool retry;
  final bool forceRefresh;
  
  const LoadReceiverPublicKey(
    this.receiverId, {
    this.retry = false,
    this.forceRefresh = false,
  });
}

/// Decrypt a message
class DecryptMessage extends EncryptionEvent {
  final String messageId;
  final String encryptedText;
  final bool isOwnMessage;
  final String keyVersion;
  final int retryCount;
  
  // Security fields
  final String? nonce;
  final DateTime? timestamp;
  final String? idempotencyKey;
  final String? hmac;
  final String senderId;
  final String? encryptedAesKey;
  final String? iv;
  
  const DecryptMessage({
    required this.messageId,
    required this.encryptedText,
    required this.isOwnMessage,
    required this.senderId,
    this.keyVersion = '',
    this.retryCount = 0,
    this.nonce,
    this.timestamp,
    this.idempotencyKey,
    this.hmac,
    this.encryptedAesKey,
    this.iv,
  });
}

/// Batch decrypt messages
class BatchDecryptMessages extends EncryptionEvent {
  final List<Map<String, dynamic>> messages;
  
  const BatchDecryptMessages(this.messages);
}

/// Message successfully decrypted
class MessageDecrypted extends EncryptionEvent {
  final String messageId;
  final String decryptedText;
  final String keyVersion;
  
  const MessageDecrypted({
    required this.messageId,
    required this.decryptedText,
    this.keyVersion = '',
  });
}

/// Encryption operation failed
class EncryptionFailed extends EncryptionEvent {
  final String operation;
  final String error;
  final String? messageId;
  final bool isSecurityError;
  
  const EncryptionFailed({
    required this.operation,
    required this.error,
    this.messageId,
    this.isSecurityError = false,
  });
}

/// Clear decryption cache
class ClearDecryptCache extends EncryptionEvent {
  const ClearDecryptCache();
}

/// Invalidate specific message from cache
class InvalidateMessageCache extends EncryptionEvent {
  final String messageId;
  
  const InvalidateMessageCache(this.messageId);
}

/// Rotate encryption keys
class RotateKeys extends EncryptionEvent {
  const RotateKeys();
}

/// Keys rotation completed
class KeysRotated extends EncryptionEvent {
  final String newPublicKey;
  
  const KeysRotated(this.newPublicKey);
}

// Security Events

/// Validate session trust
class ValidateSessionTrust extends EncryptionEvent {
  final String userId;
  
  const ValidateSessionTrust(this.userId);
}

/// Handle decryption mismatch with recovery
class HandleDecryptionMismatch extends EncryptionEvent {
  final String messageId;
  final String senderId;
  final String keyVersion;
  
  const HandleDecryptionMismatch({
    required this.messageId,
    required this.senderId,
    required this.keyVersion,
  });
}

/// Validate reconnect security
class ValidateReconnectSecurity extends EncryptionEvent {
  final String userId;
  
  const ValidateReconnectSecurity(this.userId);
}

/// Check for key rotation
class CheckKeyRotation extends EncryptionEvent {
  final String userId;
  
  const CheckKeyRotation(this.userId);
}

// ============================================================================
// STATE (Enhanced with Security State)
// ============================================================================

/// Represents the encryption state with security enhancements
class EncryptionState {
  final bool isInitialized;
  final bool isLoading;
  final bool keysReady;
  final bool receiverKeyReady;
  final String? privateKey;
  final RSAPublicKey? receiverPublicKey;
  final RSAPublicKey? senderPublicKey;
  final RSAPrivateKey? cachedPrivateKey;
  final Map<String, String> decryptCache;
  final Map<String, Future<String>> pendingDecrypts;
  final Map<String, String> decryptKeyVersions;
  final Map<String, int> decryptRetryCount;
  final String? error;
  final String? receiverKeyError;
  final int receiverKeyRetryCount;
  final int activeDecryptCount;
  final bool isRotatingKeys;
  final DateTime? lastKeyRotation;
  
  // Security State
  final int sessionTrustScore;
  final List<String> securityIssues;
  final bool isSessionCompromised;
  final bool shouldRevalidateKeys;
  final DateTime? lastTrustCheck;
  final Map<String, bool> processedMessages;
  final Set<String> failedSecurityMessages;

  // Constants
  static const int maxDecryptRetries = 3;
  static const int maxConcurrentDecrypts = 10;
  static const int maxReceiverKeyRetries = 5;
  static const int minTrustScore = 50;
  static const int criticalTrustScore = 30;
  
  // Special cache values
  static const String decryptPending = '\x00PENDING\x00';
  static const String decryptFailed = '\x00FAILED\x00';
  static const String decryptKeyError = '\x00KEY_ERR\x00';
  static const String decryptSecurityError = '\x00SEC_ERR\x00';

  const EncryptionState({
    this.isInitialized = false,
    this.isLoading = false,
    this.keysReady = false,
    this.receiverKeyReady = false,
    this.privateKey,
    this.receiverPublicKey,
    this.senderPublicKey,
    this.cachedPrivateKey,
    this.decryptCache = const {},
    this.pendingDecrypts = const {},
    this.decryptKeyVersions = const {},
    this.decryptRetryCount = const {},
    this.error,
    this.receiverKeyError,
    this.receiverKeyRetryCount = 0,
    this.activeDecryptCount = 0,
    this.isRotatingKeys = false,
    this.lastKeyRotation,
    // Security
    this.sessionTrustScore = 100,
    this.securityIssues = const [],
    this.isSessionCompromised = false,
    this.shouldRevalidateKeys = false,
    this.lastTrustCheck,
    this.processedMessages = const {},
    this.failedSecurityMessages = const {},
  });

  EncryptionState copyWith({
    bool? isInitialized,
    bool? isLoading,
    bool? keysReady,
    bool? receiverKeyReady,
    String? privateKey,
    RSAPublicKey? receiverPublicKey,
    RSAPublicKey? senderPublicKey,
    RSAPrivateKey? cachedPrivateKey,
    Map<String, String>? decryptCache,
    Map<String, Future<String>>? pendingDecrypts,
    Map<String, String>? decryptKeyVersions,
    Map<String, int>? decryptRetryCount,
    String? error,
    String? receiverKeyError,
    int? receiverKeyRetryCount,
    int? activeDecryptCount,
    bool? isRotatingKeys,
    DateTime? lastKeyRotation,
    int? sessionTrustScore,
    List<String>? securityIssues,
    bool? isSessionCompromised,
    bool? shouldRevalidateKeys,
    DateTime? lastTrustCheck,
    Map<String, bool>? processedMessages,
    Set<String>? failedSecurityMessages,
  }) {
    return EncryptionState(
      isInitialized: isInitialized ?? this.isInitialized,
      isLoading: isLoading ?? this.isLoading,
      keysReady: keysReady ?? this.keysReady,
      receiverKeyReady: receiverKeyReady ?? this.receiverKeyReady,
      privateKey: privateKey ?? this.privateKey,
      receiverPublicKey: receiverPublicKey ?? this.receiverPublicKey,
      senderPublicKey: senderPublicKey ?? this.senderPublicKey,
      cachedPrivateKey: cachedPrivateKey ?? this.cachedPrivateKey,
      decryptCache: decryptCache ?? this.decryptCache,
      pendingDecrypts: pendingDecrypts ?? this.pendingDecrypts,
      decryptKeyVersions: decryptKeyVersions ?? this.decryptKeyVersions,
      decryptRetryCount: decryptRetryCount ?? this.decryptRetryCount,
      error: error ?? this.error,
      receiverKeyError: receiverKeyError,
      receiverKeyRetryCount: receiverKeyRetryCount ?? this.receiverKeyRetryCount,
      activeDecryptCount: activeDecryptCount ?? this.activeDecryptCount,
      isRotatingKeys: isRotatingKeys ?? this.isRotatingKeys,
      lastKeyRotation: lastKeyRotation ?? this.lastKeyRotation,
      sessionTrustScore: sessionTrustScore ?? this.sessionTrustScore,
      securityIssues: securityIssues ?? this.securityIssues,
      isSessionCompromised: isSessionCompromised ?? this.isSessionCompromised,
      shouldRevalidateKeys: shouldRevalidateKeys ?? this.shouldRevalidateKeys,
      lastTrustCheck: lastTrustCheck ?? this.lastTrustCheck,
      processedMessages: processedMessages ?? this.processedMessages,
      failedSecurityMessages: failedSecurityMessages ?? this.failedSecurityMessages,
    );
  }

  /// Check if message is decrypted
  bool isMessageDecrypted(String messageId) {
    final value = decryptCache[messageId];
    return value != null && 
           value != decryptPending && 
           value != decryptFailed && 
           value != decryptKeyError &&
           value != decryptSecurityError;
  }

  /// Get decrypted text for message
  String? getDecryptedText(String messageId) {
    final value = decryptCache[messageId];
    if (value != null && 
        value != decryptPending && 
        value != decryptFailed && 
        value != decryptKeyError &&
        value != decryptSecurityError) {
      return value;
    }
    return null;
  }

  /// Check if message is pending decryption
  bool isPendingDecryption(String messageId) {
    return decryptCache[messageId] == decryptPending ||
           pendingDecrypts.containsKey(messageId);
  }

  /// Check if message failed security validation
  bool hasSecurityError(String messageId) {
    return decryptCache[messageId] == decryptSecurityError ||
           failedSecurityMessages.contains(messageId);
  }

  /// Check if can perform more concurrent decryptions
  bool get canDecryptMore => activeDecryptCount < maxConcurrentDecrypts;

  /// Check if all keys are ready
  bool get allKeysReady => keysReady && receiverKeyReady;

  /// Check if session is healthy
  bool get isSessionHealthy => sessionTrustScore >= minTrustScore && !isSessionCompromised;

  /// Check if security warnings should be shown
  bool get hasSecurityWarnings => sessionTrustScore < 70 && sessionTrustScore >= minTrustScore;
}

// ============================================================================
// BLOC (Enhanced with Security)
// ============================================================================

/// Enhanced BLoC for managing encryption operations with enterprise security
/// 
/// Security Features:
/// - Replay attack protection via nonce validation
/// - Message integrity verification via HMAC
/// - Session trust scoring
/// - Duplicate processing prevention
/// - Key rotation detection
/// - Mismatch recovery with trust scoring
class EncryptionBloc extends Bloc<EncryptionEvent, EncryptionState> {
  // Queue for pending decryption tasks
  final List<_DecryptTask> _decryptQueue = [];
  
  // Security tracking
  String? _currentUserId;
  String? _receiverId;

  EncryptionBloc() : super(const EncryptionState()) {
    on<EncryptionInitialized>(_onInitialized);
    on<LoadEncryptionKeys>(_onLoadEncryptionKeys);
    on<LoadReceiverPublicKey>(_onLoadReceiverPublicKey);
    on<DecryptMessage>(_onDecryptMessage);
    on<BatchDecryptMessages>(_onBatchDecryptMessages);
    on<MessageDecrypted>(_onMessageDecrypted);
    on<EncryptionFailed>(_onEncryptionFailed);
    on<ClearDecryptCache>(_onClearDecryptCache);
    on<InvalidateMessageCache>(_onInvalidateMessageCache);
    on<RotateKeys>(_onRotateKeys);
    on<KeysRotated>(_onKeysRotated);
    
    // Security event handlers
    on<ValidateSessionTrust>(_onValidateSessionTrust);
    on<HandleDecryptionMismatch>(_onHandleDecryptionMismatch);
    on<ValidateReconnectSecurity>(_onValidateReconnectSecurity);
    on<CheckKeyRotation>(_onCheckKeyRotation);
  }

  // ==========================================================================
  // Event Handlers
  // ==========================================================================

  Future<void> _onInitialized(
    EncryptionInitialized event,
    Emitter<EncryptionState> emit,
  ) async {
    _currentUserId = event.currentUserId;
    _receiverId = event.receiverId;
    
    // Initialize lifecycle service
    await EncryptionLifecycleService.initialize(userId: event.currentUserId);
    
    emit(state.copyWith(isInitialized: true));
    
    // Load keys automatically on initialization
    add(const LoadEncryptionKeys());
    add(LoadReceiverPublicKey(event.receiverId));
    
    // Validate session trust
    add(ValidateSessionTrust(event.currentUserId));
  }

  Future<void> _onLoadEncryptionKeys(
    LoadEncryptionKeys event,
    Emitter<EncryptionState> emit,
  ) async {
    emit(state.copyWith(isLoading: true, error: null));
    
    // Clear caches if force refresh requested
    if (event.forceRefresh) {
      EncryptionLifecycleService.clearAllCache();
    }
    
    try {
      // Load private key using lifecycle service
      final privateKeyStr = await EncryptionLifecycleService.getPrivateKey();
      if (privateKeyStr == null || privateKeyStr.isEmpty) {
        throw Exception('Private key not found');
      }

      // Parse private key
      final privateKey = await EncryptionLifecycleService.getPrivateKeyParsed();
      
      // Load my public key with fingerprint
      final myKeyResult = _currentUserId != null 
          ? await EncryptionLifecycleService.getMyPublicKey(_currentUserId!)
          : null;
      
      emit(state.copyWith(
        isLoading: false,
        keysReady: true,
        privateKey: privateKeyStr,
        cachedPrivateKey: privateKey,
        senderPublicKey: myKeyResult?.publicKey,
        error: null,
      ));
    } catch (e) {
      emit(state.copyWith(
        isLoading: false,
        keysReady: false,
        error: 'Failed to load encryption keys: $e',
      ));
    }
  }

  Future<void> _onLoadReceiverPublicKey(
    LoadReceiverPublicKey event,
    Emitter<EncryptionState> emit,
  ) async {
    // Retry logic
    if (event.retry && state.receiverKeyRetryCount >= EncryptionState.maxReceiverKeyRetries) {
      emit(state.copyWith(
        receiverKeyError: 'Failed to load receiver key after ${EncryptionState.maxReceiverKeyRetries} retries',
      ));
      return;
    }

    try {
      // Load using lifecycle service with trust validation
      final result = await EncryptionLifecycleService.getReceiverPublicKey(
        event.receiverId,
        forceRefresh: event.forceRefresh,
        validateTrust: true,
      );
      
      if (result == null) {
        // Schedule retry
        if (state.receiverKeyRetryCount < EncryptionState.maxReceiverKeyRetries) {
          await Future.delayed(const Duration(seconds: 3));
          add(LoadReceiverPublicKey(event.receiverId, retry: true));
          emit(state.copyWith(
            receiverKeyRetryCount: state.receiverKeyRetryCount + 1,
          ));
        }
        return;
      }

      emit(state.copyWith(
        receiverKeyReady: true,
        receiverPublicKey: result.publicKey,
        receiverKeyError: null,
        receiverKeyRetryCount: 0,
      ));
    } catch (e) {
      emit(state.copyWith(
        receiverKeyError: 'Failed to load receiver key: $e',
      ));
      
      // Schedule retry
      if (state.receiverKeyRetryCount < EncryptionState.maxReceiverKeyRetries) {
        await Future.delayed(const Duration(seconds: 3));
        add(LoadReceiverPublicKey(event.receiverId, retry: true));
      }
    }
  }

  Future<void> _onDecryptMessage(
    DecryptMessage event,
    Emitter<EncryptionState> emit,
  ) async {
    // Security: Check idempotency (prevent duplicate processing)
    final idempotencyKey = event.idempotencyKey ?? '${event.senderId}_${event.messageId}';
    if (state.processedMessages[idempotencyKey] == true ||
        CryptoSecurityService.isMessageProcessed(idempotencyKey)) {
      _dbg('Message ${event.messageId} already processed (idempotency)');
      return;
    }

    // Check if already decrypted
    if (state.isMessageDecrypted(event.messageId)) {
      return;
    }

    // Check if already pending
    if (state.isPendingDecryption(event.messageId)) {
      return;
    }

    // Check if keys are ready
    if (!state.allKeysReady) {
      emit(state.copyWith(
        decryptCache: _updateCache(event.messageId, EncryptionState.decryptKeyError),
      ));
      return;
    }

    // Check session trust
    if (!state.isSessionHealthy) {
      _dbg('Session trust score ${state.sessionTrustScore}, may have issues');
      // Still attempt decryption but log warning
    }

    // Check retry count
    final retryCount = state.decryptRetryCount[event.messageId] ?? 0;
    if (retryCount >= EncryptionState.maxDecryptRetries) {
      emit(state.copyWith(
        decryptCache: _updateCache(event.messageId, EncryptionState.decryptFailed),
      ));
      return;
    }

    // Mark as pending
    emit(state.copyWith(
      decryptCache: _updateCache(event.messageId, EncryptionState.decryptPending),
    ));

    // Queue or execute immediately
    if (state.canDecryptMore) {
      await _executeDecrypt(event, emit);
    } else {
      _decryptQueue.add(_DecryptTask(event));
    }
  }

  Future<void> _executeDecrypt(
    DecryptMessage event,
    Emitter<EncryptionState> emit,
  ) async {
    emit(state.copyWith(
      activeDecryptCount: state.activeDecryptCount + 1,
    ));

    try {
      String decrypted;
      
      // Security validation
      // BUG 8 FIX: Check if encryptedAesKey is null and emit error instead of using empty string
      final encryptedAesKey = event.encryptedAesKey;
      final iv = event.iv;
      if (encryptedAesKey == null || iv == null) {
        throw Exception('Missing encryption keys: encryptedAesKey or iv is null');
      }
      
      if (event.nonce != null && event.timestamp != null) {
        // New secure message with validation
        // Derive HMAC key for integrity verification
        final Uint8List? hmacKey = await _getHmacKeySafe();
        
        if (hmacKey == null) {
          // HMAC key unavailable - emit EncryptionFailed and abort
          _dbg('HMAC key unavailable for message ${event.messageId}');
          emit(state.copyWith(
            decryptCache: _updateCache(event.messageId, EncryptionState.decryptFailed),
            error: 'HMAC key unavailable - integrity verification required',
          ));
          add(EncryptionFailed(
            operation: 'decrypt',
            error: 'HMAC key unavailable - cannot verify message integrity',
            messageId: event.messageId,
          ));
          return;
        }
        
        decrypted = await CryptoSecurityService.decryptSecure(
          ciphertext: event.encryptedText,
          aesKey: encryptedAesKey,
          iv: iv,
          messageId: event.messageId,
          senderId: event.senderId,
          nonce: event.nonce,
          timestamp: event.timestamp?.toIso8601String(),
          idempotencyKey: event.idempotencyKey,
          hmac: event.hmac,
          hmacKey: hmacKey,
        );
      } else {
        // Legacy message (backward compatibility)
        decrypted = await EncryptionHelper.decryptMessage(
          event.encryptedText,
          encryptedAesKey,
          iv,
        );
      }

      // Mark idempotency
      final idempotencyKey = event.idempotencyKey ?? '${event.senderId}_${event.messageId}';
      final newProcessed = Map<String, bool>.from(state.processedMessages)
        ..[idempotencyKey] = true;
      
      // Record successful decryption for trust tracking
      EncryptionLifecycleService.recordSuccessfulDecryption(event.senderId);

      add(MessageDecrypted(
        messageId: event.messageId,
        decryptedText: decrypted,
        keyVersion: event.keyVersion,
      ));
      
      emit(state.copyWith(processedMessages: newProcessed));
    } on SecurityValidationException catch (e) {
      // Security error - mark as failed security
      _dbg('Security validation failed: $e');
      
      final newFailed = Set<String>.from(state.failedSecurityMessages)
        ..add(event.messageId);
      
      add(EncryptionFailed(
        operation: 'decrypt',
        error: e.toString(),
        messageId: event.messageId,
        isSecurityError: true,
      ));
      
      emit(state.copyWith(
        decryptCache: _updateCache(event.messageId, EncryptionState.decryptSecurityError),
        failedSecurityMessages: newFailed,
      ));
      
      // Handle mismatch if applicable
      if (e.toString().contains('mismatch') || e.toString().contains('failed')) {
        add(HandleDecryptionMismatch(
          messageId: event.messageId,
          senderId: event.senderId,
          keyVersion: event.keyVersion,
        ));
      }
    } catch (e) {
      add(EncryptionFailed(
        operation: 'decrypt',
        error: e.toString(),
        messageId: event.messageId,
      ));
    } finally {
      emit(state.copyWith(
        activeDecryptCount: state.activeDecryptCount - 1,
      ));
      _processDecryptQueue(emit);
    }
  }

  void _processDecryptQueue(Emitter<EncryptionState> emit) {
    while (_decryptQueue.isNotEmpty && state.canDecryptMore) {
      final task = _decryptQueue.removeAt(0);
      _executeDecrypt(task.event, emit);
    }
  }

  /// Safely retrieves the current HMAC key
  /// Returns null if the key is unavailable
  Future<Uint8List?> _getHmacKeySafe() async {
    try {
      return HmacKeyService.getHmacKey();
    } catch (e) {
      _dbg('Failed to get HMAC key: $e');
      return null;
    }
  }

  Future<void> _onBatchDecryptMessages(
    BatchDecryptMessages event,
    Emitter<EncryptionState> emit,
  ) async {
    for (final message in event.messages) {
      add(DecryptMessage(
        messageId: message['id'] as String,
        encryptedText: message['text'] as String,
        isOwnMessage: message['isMe'] as bool,
        senderId: message['senderId'] as String,
        keyVersion: message['keyVersion'] as String? ?? '',
        nonce: message['nonce'] as String?,
        timestamp: message['timestamp'] != null 
            ? DateTime.tryParse(message['timestamp'])
            : null,
        idempotencyKey: message['idempotencyKey'] as String?,
        hmac: message['hmac'] as String?,
        encryptedAesKey: message['encryptedAesKey'] as String? ?? message['aesKey'] as String?,
        iv: message['iv'] as String?,
      ));
    }
  }

  void _onMessageDecrypted(
    MessageDecrypted event,
    Emitter<EncryptionState> emit,
  ) {
    emit(state.copyWith(
      decryptCache: _updateCache(event.messageId, event.decryptedText),
      decryptKeyVersions: {...state.decryptKeyVersions, event.messageId: event.keyVersion},
    ));
  }

  void _onEncryptionFailed(
    EncryptionFailed event,
    Emitter<EncryptionState> emit,
  ) {
    // Update retry count
    final newRetryCount = {...state.decryptRetryCount};
    if (event.messageId != null) {
      newRetryCount[event.messageId!] = (newRetryCount[event.messageId!] ?? 0) + 1;
    }

    emit(state.copyWith(
      decryptCache: event.messageId != null 
          ? _updateCache(event.messageId!, EncryptionState.decryptFailed)
          : null,
      decryptRetryCount: newRetryCount,
    ));
  }

  void _onClearDecryptCache(
    ClearDecryptCache event,
    Emitter<EncryptionState> emit,
  ) {
    emit(state.copyWith(
      decryptCache: const {},
      pendingDecrypts: const {},
      decryptKeyVersions: const {},
      decryptRetryCount: const {},
      processedMessages: const {},
      failedSecurityMessages: const {},
    ));
  }

  void _onInvalidateMessageCache(
    InvalidateMessageCache event,
    Emitter<EncryptionState> emit,
  ) {
    final newCache = Map<String, String>.from(state.decryptCache)
      ..remove(event.messageId);
    final newVersions = Map<String, String>.from(state.decryptKeyVersions)
      ..remove(event.messageId);
    final newRetries = Map<String, int>.from(state.decryptRetryCount)
      ..remove(event.messageId);

    emit(state.copyWith(
      decryptCache: newCache,
      decryptKeyVersions: newVersions,
      decryptRetryCount: newRetries,
    ));
  }

  Future<void> _onRotateKeys(
    RotateKeys event,
    Emitter<EncryptionState> emit,
  ) async {
    emit(state.copyWith(isRotatingKeys: true));
    
    try {
      // Step 1: Generate new RSA key pair
      final keyPair = await RSAHelper.generateKeyPair();
      final privateKey = keyPair.privateKey;
      final publicKey = keyPair.publicKey;
      
      // Extract key components
      final nStr = publicKey.modulus.toString();
      final eStr = publicKey.exponent.toString();
      
      // Step 2: Store private key securely using flutter_secure_storage
      final privateKeyData = jsonEncode({
        'n': privateKey.n.toString(),
        'd': privateKey.privateExponent.toString(),
        'p': privateKey.p.toString(),
        'q': privateKey.q.toString(),
      });
      
      const secureStorage = FlutterSecureStorage();
      await secureStorage.write(key: 'private_key', value: privateKeyData);
      
      // Step 3: Upload new public key to Firestore
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('No authenticated user');
      }
      
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set({
            'publicKey': {'n': nStr, 'e': eStr},
            'publicKeyVersion': _keyVersion(nStr),
            'keyUpdatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
      
      // Step 4: Mark encryption as set up
      await secureStorage.write(key: 'encryption_setup_done', value: 'true');
      
      // Step 5: Emit KeysRotated with the new public key string
      final publicKeyStr = '$nStr,$eStr';
      add(KeysRotated(publicKeyStr));
      
    } catch (e) {
      // Storage failed - emit error and do not publish the new public key
      _dbg('Key rotation failed: $e');
      emit(state.copyWith(
        isRotatingKeys: false,
        error: 'Key rotation failed: $e',
      ));
    }
  }
  
  /// Helper to generate key version from modulus
  String _keyVersion(String modulus) {
    // Use first 16 chars of SHA-256 hash as version identifier
    final bytes = utf8.encode(modulus);
    final digest = SHA256Digest().process(Uint8List.fromList(bytes));
    return digest.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _onKeysRotated(
    KeysRotated event,
    Emitter<EncryptionState> emit,
  ) {
    emit(state.copyWith(
      isRotatingKeys: false,
      lastKeyRotation: DateTime.now(),
    ));

    // Clear cache after key rotation
    add(const ClearDecryptCache());
    
    // Clear lifecycle cache
    EncryptionLifecycleService.clearAllCache();
  }

  // ==========================================================================
  // Security Event Handlers
  // ==========================================================================

  Future<void> _onValidateSessionTrust(
    ValidateSessionTrust event,
    Emitter<EncryptionState> emit,
  ) async {
    final result = CryptoSecurityService.validateSession(
      userId: event.userId,
      keyVersion: _myKeyVersionCache,
      sessionCreated: null, // Session created time not tracked
      lastActivity: DateTime.now(), // Current activity
      expectedKeyVersion: null, // Could be passed from server
    );

    emit(state.copyWith(
      sessionTrustScore: result.trustScore,
      securityIssues: result.issues,
      isSessionCompromised: result.isCompromised,
      shouldRevalidateKeys: result.recommendation == SessionRecommendation.revalidate ||
                             result.recommendation == SessionRecommendation.rotateKeys,
      lastTrustCheck: DateTime.now(),
    ));

    // Session trust rotation recommendation handling removed
  }

  Future<void> _onHandleDecryptionMismatch(
    HandleDecryptionMismatch event,
    Emitter<EncryptionState> emit,
  ) async {
    final result = EncryptionLifecycleService.handleDecryptionMismatch(
      event.senderId,
      messageId: event.messageId,
      keyVersion: event.keyVersion,
    );

    if (result.shouldNotifyUser && result.message != null) {
      emit(state.copyWith(
        error: result.message,
        securityIssues: [...state.securityIssues, result.message!],
      ));
    }

    if (result.shouldClearCache) {
      EncryptionLifecycleService.clearReceiverCache(event.senderId);
    }

    if (result.shouldRetry) {
      // Retry will happen on next decryption attempt with fresh keys
      _dbg('Will retry decryption with fresh keys for ${event.messageId}');
    }
  }

  Future<void> _onValidateReconnectSecurity(
    ValidateReconnectSecurity event,
    Emitter<EncryptionState> emit,
  ) async {
    final result = await EncryptionLifecycleService.validateReconnectSecurity(
      event.userId,
    );

    emit(state.copyWith(
      sessionTrustScore: result.trustScore,
      securityIssues: [...state.securityIssues, ...result.issues],
      shouldRevalidateKeys: result.shouldRevalidateKeys,
    ));

    if (result.shouldRevalidateKeys) {
      // Trigger key revalidation
      add(const LoadEncryptionKeys(forceRefresh: true));
      if (_receiverId != null) {
        add(LoadReceiverPublicKey(_receiverId!, forceRefresh: true));
      }
    }
  }

  Future<void> _onCheckKeyRotation(
    CheckKeyRotation event,
    Emitter<EncryptionState> emit,
  ) async {
    final status = await EncryptionLifecycleService.checkKeyRotation(event.userId);

    switch (status) {
      case KeyRotationStatus.recent:
        emit(state.copyWith(
          shouldRevalidateKeys: true,
          securityIssues: [...state.securityIssues, 'Keys recently rotated'],
        ));
        // Clear and reload keys
        add(const LoadEncryptionKeys(forceRefresh: true));
        if (_receiverId != null) {
          add(LoadReceiverPublicKey(_receiverId!, forceRefresh: true));
        }
        break;
      case KeyRotationStatus.stable:
        // Keys stable after rotation
        emit(state.copyWith(
          shouldRevalidateKeys: false,
        ));
        break;
      case KeyRotationStatus.scheduled:
        emit(state.copyWith(
          securityIssues: [...state.securityIssues, 'Key rotation scheduled'],
        ));
        break;
      default:
        break;
    }
  }

  // ==========================================================================
  // Helpers
  // ==========================================================================

  Map<String, String> _updateCache(String messageId, String value) {
    return {...state.decryptCache, messageId: value};
  }

  void _dbg(String message) {
    assert(() {
      debugPrint('[EncryptionBloc] $message');
      return true;
    }());
  }

  /// Static decrypt function for isolate execution
  /// Runs in a Flutter compute() isolate - no Flutter bindings available
  /// Uses only pure Dart crypto operations
  static String _decryptIsolate(Map<String, dynamic> params) {
    try {
      // Extract parameters from the map
      final encryptedText = params['encryptedText'] as String;
      final encryptedAesKey = params['encryptedAesKey'] as String;
      final iv = params['iv'] as String;
      final privateKeyPem = params['privateKeyPem'] as String;
      
      // Parse the private key from PEM format
      final privateKey = _parsePrivateKeyFromPem(privateKeyPem);
      
      // Step 1: Decrypt the AES key using RSA
      final aesKey = _rsaDecryptSync(encryptedAesKey, privateKey);
      
      // Step 2: Decrypt the message using AES
      final plaintext = _aesDecryptSync(encryptedText, aesKey, iv);
      
      return plaintext;
    } catch (e) {
      // Return a sentinel value that the caller can detect
      // This allows the isolate to complete without crashing
      return '\x00DECRYPT_ERROR\x00${e.toString()}';
    }
  }
  
  /// Parses an RSA private key from JSON PEM format
  /// This is a synchronous operation suitable for isolates
  static Map<String, String> _parsePrivateKeyFromPem(String pemJson) {
    final keyData = jsonDecode(pemJson) as Map<String, dynamic>;
    return {
      'n': keyData['n'] as String,
      'd': keyData['d'] as String,
      'p': keyData['p'] as String,
      'q': keyData['q'] as String,
    };
  }
  
  /// Synchronous RSA decryption using PKCS1 padding
  /// Pure Dart implementation - no Flutter dependencies
  static String _rsaDecryptSync(String encryptedText, Map<String, String> privKeyMap) {
    final privateKey = RSAPrivateKey(
      BigInt.parse(privKeyMap['n']!),
      BigInt.parse(privKeyMap['d']!),
      BigInt.parse(privKeyMap['p']!),
      BigInt.parse(privKeyMap['q']!),
    );
    final inputBytes = base64Decode(encryptedText);
    final cipher = PKCS1Encoding(RSAEngine())
      ..init(false, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    final output = cipher.process(inputBytes);
    return base64Encode(output);
  }
  
  /// Synchronous AES-256-CBC decryption with PKCS7 padding
  /// Pure Dart implementation - no Flutter dependencies
  static String _aesDecryptSync(String encryptedText, String key, String ivBase64) {
    final keyBytes = base64Decode(key);
    final iv = base64Decode(ivBase64);
    
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    cipher.init(
      false, // decrypt mode
      PaddedBlockCipherParameters(
        ParametersWithIV(KeyParameter(keyBytes), iv),
        null,
      ),
    );
    
    final input = base64Decode(encryptedText);
    final output = cipher.process(input);
    return utf8.decode(output);
  }

  String? get _myKeyVersionCache => EncryptionLifecycleService.getMyFingerprint();

  @override
  Future<void> close() {
    _decryptQueue.clear();
    return super.close();
  }
}

// ============================================================================
// Helper Classes
// ============================================================================

class _DecryptTask {
  final DecryptMessage event;
  
  _DecryptTask(this.event);
}

// ============================================================================
// Event Bus Event Classes (for cross-bloc communication)
// ============================================================================

class EncryptionStateChangedEvent {
  final bool keysReady;
  final bool? receiverKeyReady;
  final String traceId;

  const EncryptionStateChangedEvent({
    required this.keysReady,
    this.receiverKeyReady,
    required this.traceId,
  });
}

class EncryptionErrorEvent {
  final String error;
  final String traceId;

  const EncryptionErrorEvent({
    required this.error,
    required this.traceId,
  });
}

class KeyRotatedEvent {
  final String newPublicKey;
  final String traceId;

  const KeyRotatedEvent({
    required this.newPublicKey,
    required this.traceId,
  });
}

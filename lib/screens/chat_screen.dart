import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:just_audio/just_audio.dart';

import '../main.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import 'game_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import '../utils/avatar_utils.dart';
import '../utils/encryption.dart';
import '../utils/rsa_helper.dart';
import '../utils/input_validator.dart';

class ChatScreen extends StatefulWidget {
  final String receiverId;

  const ChatScreen({super.key, required this.receiverId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final currentUser = FirebaseAuth.instance.currentUser!;
  final storage = const FlutterSecureStorage();
  final controller = TextEditingController();
  final searchController = TextEditingController();

  String? privateKeyStr;
  RSAPublicKey? receiverPublicKey;
  RSAPublicKey? senderPublicKey;
  RSAPrivateKey? _cachedPrivateKey;

  bool _keysReady = false;
  bool _roomExists = false;
  String? _keyError;
  String? _receiverKeyError;

  // ── Reply-to ──────────────────────────────────────────────────────────
  Map<String, dynamic>? _replyToData; // {messageId, preview}

  // ── Edit mode ─────────────────────────────────────────────────────────
  DocumentSnapshot? _editingDoc;

  // ── Offline queue ─────────────────────────────────────────────────────
  bool _isOnline = true;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  static const _kDecryptPending = '\x00PENDING\x00';
  static const _kDecryptFailed = '\x00FAILED\x00';
  static const _kDecryptKeyError = '\x00KEY_ERR\x00';
  final Map<String, String> _decryptCache = {};
  final Map<String, Future<String>> _pendingDecrypts = {};

  bool _isSelecting = false;
  final Set<String> _selectedIds = {};
  final Map<String, DocumentSnapshot> _selectedDocs = {};

  bool isSearching = false;
  String searchQuery = "";

  bool _showEmojiPicker = false;

  Timer? activityTimer;
  Timer? typingTimer;
  bool isTyping = false;

  final ScrollController scrollController = ScrollController();

  int _messageListRebuildCount = 0;
  int _decryptKeyErrorCount = 0;
  DateTime? _lastDecryptRebuildTime;
  Set<String> _processedDecryptDocIds = {};

  String _receiverName = "User";

  String? _myKeyVersion;

  final AudioPlayer _audioPlayer = AudioPlayer();

  Stream<QuerySnapshot>? _messageStream;

  int _previousMessageCount = -1;
  bool _isScreenActive = true;
  DateTime? _lastSeenMarkTime;

  static void _dbg(String message) {
    debugPrint('[ChatScreen] $message');
  }

  String getRoomId(String u1, String u2) => ChatService.getRoomId(u1, u2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeScreen();
  }

  Future<void> _initializeScreen() async {
    debugPrint('[ChatScreen] _initializeScreen: START');

    // ── Connectivity ───────────────────────────────────────────────────
    final initial = await Connectivity().checkConnectivity();
    _isOnline = initial.any((r) => r != ConnectivityResult.none);
    debugPrint('[ChatScreen] _initializeScreen: online=$_isOnline');
    await _loadKeys();

    if (!mounted) return;

    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online && !_isOnline) _flushOfflineQueue();
      if (mounted) setState(() => _isOnline = online);
    });

    if (!mounted) return;

    await _initAudio();
    try {
      await _checkRoomExists();
    } catch (e) {
      _dbg('_initializeScreen: _checkRoomExists threw — $e (non-fatal)');
    }

    // Fetch receiver name once — removed from AppBar stream to eliminate nested rebuilds
    try {
      final userSnap = await FirebaseFirestore.instance
          .collection("users")
          .doc(widget.receiverId)
          .get();
      if (userSnap.exists && userSnap.data() != null) {
        final userData = userSnap.data() as Map<String, dynamic>;
        final name = userData["name"] as String? ?? "User";
        _receiverName = InputValidator.stripInvisible(name);
        _dbg('_initializeScreen: loaded receiver name="$_receiverName"');
      }
    } catch (e) {
      _dbg('_initializeScreen: failed to load receiver name — $e');
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ChatService.markMessagesAsDelivered(
        currentUser.uid,
        widget.receiverId,
      ).then((_) => _markSeenIfActive());
    });

    await ChatService.updateLastSeenTimestamp(
      currentUser.uid,
      widget.receiverId,
    );
    debugPrint('[ChatScreen] _initializeScreen: COMPLETE');
    activityTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_keysReady || !mounted) return;
      ChatService.updateLastSeenTimestamp(currentUser.uid, widget.receiverId);
      if (_isScreenActive) {
        ChatService.markMessagesAsDelivered(
          currentUser.uid,
          widget.receiverId,
        ).then((_) => _markSeenIfActive());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    activityTimer?.cancel();
    typingTimer?.cancel();
    _connectivitySub?.cancel();
    scrollController.dispose();
    controller.dispose();
    searchController.dispose();
    _audioPlayer.dispose();
    ChatService.updateTyping(currentUser.uid, widget.receiverId, false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _isScreenActive = true;
      ChatService.markMessagesAsDelivered(
        currentUser.uid,
        widget.receiverId,
      ).then((_) => _markSeenIfActive());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _isScreenActive = false;
    }
  }

  Future<void> _markSeenIfActive() async {
    if (!_isScreenActive || !mounted) return;
    final now = DateTime.now();
    if (_lastSeenMarkTime != null &&
        now.difference(_lastSeenMarkTime!).inMilliseconds < 500) {
      return;
    }
    _lastSeenMarkTime = now;
    await ChatService.markMessagesAsSeen(currentUser.uid, widget.receiverId);
  }

  Future<void> _initAudio() async {
    try {
      await _audioPlayer.setAsset('assets/sounds/message.mp3');
    } catch (e) {
      _dbg('audio init error: ${e.runtimeType}');
    }
  }

  Future<void> _onNewMessageReceived() async {
    await SettingsScreen.vibrateIfEnabled();
    final soundEnabled = await SettingsScreen.isSoundEnabled();
    if (soundEnabled) {
      try {
        await _audioPlayer.seek(Duration.zero);
        await _audioPlayer.play();
      } catch (e) {
        _dbg('sound play error: ${e.runtimeType}');
      }
    }
  }

  Future<void> updateTyping(bool typing) async {
    await ChatService.updateTyping(currentUser.uid, widget.receiverId, typing);
  }

  Future<void> _checkRoomExists() async {
    debugPrint('[ChatScreen] _checkRoomExists: START');
    final roomId = ChatService.getRoomId(currentUser.uid, widget.receiverId);
    try {
      final doc = await FirebaseFirestore.instance
          .collection("chat_rooms")
          .doc(roomId)
          .get()
          .timeout(const Duration(seconds: 8));
      if (mounted && doc.exists) {
        setState(() => _roomExists = true);
      }
    } catch (e) {
      _dbg('_checkRoomExists: failed — ${e.runtimeType} (non-fatal)');
    }
  }

  Future<void> _loadKeys() async {
    _dbg('_loadKeys: starting');

    final results = await Future.wait([
      ChatService.loadPrivateKey(),
      ChatService.loadReceiverPublicKey(widget.receiverId),
      ChatService.loadReceiverPublicKey(currentUser.uid),
    ]);

    privateKeyStr = results[0] as String?;

    final receiverResult = results[1] as PublicKeyResult?;
    final senderResult = results[2] as PublicKeyResult?;

    receiverPublicKey = receiverResult?.publicKey;
    senderPublicKey = senderResult?.publicKey;
    _myKeyVersion = senderResult?.version;

    debugPrint(
      '[ChatScreen] _loadKeys: privateKey=${privateKeyStr != null}, receiver=${receiverPublicKey != null}, sender=${senderPublicKey != null}',
    );

    final cachedReceiverVersion = await storage.read(
      key: 'receiver_key_version_${widget.receiverId}',
    );
    final currentReceiverVersion = receiverResult?.version;

    if (cachedReceiverVersion != null &&
        currentReceiverVersion != null &&
        cachedReceiverVersion != currentReceiverVersion) {
      _decryptCache.clear();
      _dbg('receiver key version changed — cache cleared');
      if (mounted) _showKeyRotationBanner();
    }

    if (currentReceiverVersion != null) {
      await storage.write(
        key: 'receiver_key_version_${widget.receiverId}',
        value: currentReceiverVersion,
      );
    }

    _dbg(
      '_loadKeys: '
      'privateKey=${privateKeyStr != null ? "loaded" : "null"} '
      'receiverKey=${receiverPublicKey != null ? "loaded" : "null"} '
      'senderKey=${senderPublicKey != null ? "loaded" : "null"}',
    );

    assert(() {
      if (privateKeyStr != null && senderPublicKey != null) {
        try {
          final testBytes = Uint8List(32);
          final testInput = base64Encode(testBytes);

          final keyData = jsonDecode(privateKeyStr!);
          final privateKey = RSAPrivateKey(
            BigInt.parse(keyData["n"]),
            BigInt.parse(keyData["d"]),
            BigInt.parse(keyData["p"]),
            BigInt.parse(keyData["q"]),
          );

          // RSA self-test: encrypt + decrypt in background isolate
          RSAHelper.encrypt(testInput, senderPublicKey!)
              .then((encrypted) {
                return RSAHelper.decrypt(encrypted, privateKey).then((
                  decrypted,
                ) {
                  if (decrypted == testInput) {
                    debugPrint('[ChatScreen] RSA self-test: PASSED');
                  } else {
                    debugPrint('[ChatScreen] RSA self-test: MISMATCH');
                  }
                });
              })
              .catchError((e) {
                debugPrint(
                  '[ChatScreen] RSA self-test: FAILED ${e.runtimeType}',
                );
              });
        } catch (e) {
          debugPrint('[ChatScreen] RSA self-test: FAILED ${e.runtimeType}');
        }
      }
      return true;
    }());

    if (receiverPublicKey == null) {
      debugPrint('[ChatScreen] _loadKeys: RETRY loop starting (5 attempts)');
      for (int i = 0; i < 5; i++) {
        await Future.delayed(Duration(seconds: (i + 1) * 2)); // 2,4,6,8,10s
        final retryResult = await ChatService.loadReceiverPublicKey(
          widget.receiverId,
          forceServer: i >= 2,
        );
        receiverPublicKey = retryResult?.publicKey;
        _dbg(
          'retry ${i + 1}: ${receiverPublicKey != null ? "loaded" : "null"}',
        );
        if (receiverPublicKey != null) break;
      }
    }

    if (mounted) {
      setState(() {
        // Remove only failed entries, preserve pending ones
        _decryptCache.removeWhere((_, v) => v == _kDecryptFailed);
        _cachedPrivateKey = null;

        // Own keys must be ready to send/receive
        final ownKeysReady = privateKeyStr != null && senderPublicKey != null;
        _keysReady = ownKeysReady;

        if (privateKeyStr == null) {
          _keyError =
              "Your private key is missing. Please log out and log in again.";
        } else if (senderPublicKey == null) {
          _keyError =
              "Your public key is missing. Please log out and log in again.";
        } else if (receiverPublicKey == null) {
          // Receiver hasn't set up yet - this is a warning, not a blocking error
          _keyError = null;
          _receiverKeyError =
              "Waiting for $_receiverName to set up encryption...";
        } else {
          _keyError = null;
          _receiverKeyError = null;
          _decryptKeyErrorCount = 0;
          _decryptCache.clear();

          if (_keysReady && _messageStream == null) {
            final chatRoomId = ChatService.getRoomId(
              currentUser.uid,
              widget.receiverId,
            );
            _messageStream = FirebaseFirestore.instance
                .collection("chat_rooms")
                .doc(chatRoomId)
                .collection("messages")
                .orderBy("timestamp")
                .limitToLast(50)
                .snapshots();
            _dbg('_loadKeys: message stream initialized');
          }
        }

        _dbg(
          '_loadKeys: ready=$_keysReady ownError=$_keyError receiverError=$_receiverKeyError',
        );
      });
    }
  }

  void _showKeyRotationBanner() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.lock_reset, color: Colors.white, size: 16),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                "The other person's encryption key changed. "
                "Older messages may not decrypt on their device.",
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.orange.shade700,
        duration: const Duration(seconds: 6),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> sendMessage() async {
    final rawText = controller.text.trim();

    if (rawText.isEmpty) {
      _dbg('send: aborted — empty text');
      return;
    }
    if (!_keysReady) {
      _dbg('send: aborted — keys not ready');
      return;
    }

    final error = InputValidator.validateMessage(rawText);
    if (error != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
      return;
    }

    // ── Edit mode ──────────────────────────────────────────────────────
    if (_editingDoc != null) {
      final doc = _editingDoc!;
      final oldData = doc.data() as Map<String, dynamic>;
      final roomId = ChatService.getRoomId(currentUser.uid, widget.receiverId);
      final encryptedData = await EncryptionHelper.encryptMessage(rawText);
      final newAesForReceiver = await RSAHelper.encrypt(
        encryptedData["key"]!,
        receiverPublicKey!,
      );
      final newAesForSender = await RSAHelper.encrypt(
        encryptedData["key"]!,
        senderPublicKey!,
      );
      try {
        await ChatService.editMessage(
          chatRoomId: roomId,
          messageId: doc.id,
          newEncryptedText: encryptedData["text"]!,
          newAesKeyForReceiver: newAesForReceiver,
          newAesKeyForSender: newAesForSender,
          newIv: encryptedData["iv"]!,
          originalEncryptedText: oldData["text"] as String? ?? "",
        );
        _decryptCache.remove(doc.id); // force re-decrypt
      } catch (e) {
        _dbg('edit: failed — ${e.runtimeType}');
      }
      setState(() => _editingDoc = null);
      updateTyping(false);
      typingTimer?.cancel();
      isTyping = false;
      controller.clear();
      return;
    }

    updateTyping(false);
    typingTimer?.cancel();
    isTyping = false;
    final replySnapshot = _replyToData;
    setState(() => _replyToData = null);
    controller.clear();

    // ── Check receiver key availability ─────────────────────────────────
    if (receiverPublicKey == null) {
      _dbg('send: receiver key not available');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "This user hasn't set up encryption yet. They need to open the app first.",
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    // ── Offline queue ──────────────────────────────────────────────────
    if (!_isOnline) {
      await OfflineMessageQueue.enqueue({
        "receiverId": widget.receiverId,
        "text": rawText,
        if (replySnapshot != null) "replyTo": replySnapshot,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "You're offline. Message queued and will send when reconnected.",
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    try {
      await ChatService.sendMessage(
        currentUserId: currentUser.uid,
        receiverId: widget.receiverId,
        text: rawText,
        receiverPublicKey: receiverPublicKey!,
        senderPublicKey: senderPublicKey!,
        replyTo: replySnapshot,
      );
      debugPrint(
        '[ChatScreen] sendMessage: SUCCESS, text length=${rawText.length}',
      );
      _dbg('send: success');
      if (!_roomExists && mounted) {
        setState(() => _roomExists = true);
      }
    } catch (e) {
      debugPrint('[ChatScreen] sendMessage: FAILED ${e.runtimeType}');
      _dbg('send: failed — ${e.runtimeType}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to send message. Please try again.'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// Flushes queued offline messages when connectivity is restored.
  Future<void> _flushOfflineQueue() async {
    if (!_keysReady || receiverPublicKey == null || senderPublicKey == null) {
      return;
    }
    final queued = await OfflineMessageQueue.dequeueAll();
    for (final entry in queued) {
      final payload = entry.value;
      // Only flush messages for this chat
      if (payload["receiverId"] != widget.receiverId) continue;
      try {
        await ChatService.sendMessage(
          currentUserId: currentUser.uid,
          receiverId: widget.receiverId,
          text: payload["text"] as String,
          receiverPublicKey: receiverPublicKey!,
          senderPublicKey: senderPublicKey!,
          replyTo: payload["replyTo"] as Map<String, dynamic>?,
        );
        await OfflineMessageQueue.remove(entry.key);
      } catch (e) {
        _dbg('flush queue: failed for ${entry.key} — ${e.runtimeType}');
        break; // stop on first failure, retry next time
      }
    }
  }

  RSAPrivateKey? _getOrParsePrivateKey() {
    if (_cachedPrivateKey != null) return _cachedPrivateKey;
    if (privateKeyStr == null) return null;

    try {
      final keyData = jsonDecode(privateKeyStr!);
      _cachedPrivateKey = RSAPrivateKey(
        BigInt.parse(keyData["n"]),
        BigInt.parse(keyData["d"]),
        BigInt.parse(keyData["p"]),
        BigInt.parse(keyData["q"]),
      );
      return _cachedPrivateKey;
    } catch (e) {
      _dbg('_getOrParsePrivateKey: failed to parse — ${e.runtimeType}');
      return null;
    }
  }

  String _decryptCached(String docId, Map<String, dynamic> data) {
    final cached = _decryptCache[docId];
    if (cached != null && cached != _kDecryptPending) return cached;

    if (cached == _kDecryptPending) {
      return '🔒';
    }

    final msgKeyVersion = data["receiverKeyVersion"] as String?;
    if (msgKeyVersion == null) {
      _dbg('decrypt[$docId]: no receiverKeyVersion; attempting legacy decrypt');
    } else if (_myKeyVersion != null && msgKeyVersion != _myKeyVersion) {
      _dbg(
        'decrypt[$docId]: key version mismatch (msg=$msgKeyVersion, loaded=$_myKeyVersion)',
      );
      if (!_decryptCache.containsKey(docId)) {
        _decryptCache[docId] = _kDecryptKeyError;
        _decryptKeyErrorCount++;
      }
      return _kDecryptKeyError;
    }

    final privateKey = _getOrParsePrivateKey();
    if (privateKey == null) {
      _dbg('decrypt[$docId]: private key not loaded');
      return '🔒';
    }

    try {
      final aesKeyEncrypted = data["aesKey"] as String?;
      if (aesKeyEncrypted == null) {
        _dbg('decrypt[$docId]: aesKey field missing');
        _decryptCache[docId] = _kDecryptPending;
        return '🔒';
      }

      final iv = data["iv"] as String?;
      if (iv == null) {
        _dbg('decrypt[$docId]: iv field missing — cannot decrypt');
        _decryptCache[docId] = _kDecryptPending;
        return '🔒';
      }

      if (_pendingDecrypts.containsKey(docId)) return '🔒';

      _dbg(
        'decrypt[$docId]: RSA+ AES decrypt now on background isolate (was blocking main thread)',
      );
      final pending = RSAHelper.decrypt(aesKeyEncrypted, privateKey)
          .then((aesKey) async {
            final plaintext = await EncryptionHelper.decryptMessage(
              data["text"] as String,
              aesKey,
              iv,
            );
            _decryptCache[docId] = plaintext;
            _pendingDecrypts.remove(docId);
            if (_decryptCache.length > 200) {
              final keysToRemove = _decryptCache.keys
                  .take(_decryptCache.length - 150)
                  .toList();
              keysToRemove.forEach(_decryptCache.remove);
            }
            _scheduleDecryptRebuild();
            return plaintext;
          })
          .catchError((e) {
            _dbg('decrypt[$docId]: ${e.runtimeType}');
            if (e is ArgumentError) {
              _decryptCache[docId] = _kDecryptKeyError;
              _decryptKeyErrorCount++;
              _scheduleDecryptRebuild();
            } else {
              _decryptCache[docId] = _kDecryptFailed;
            }
            _pendingDecrypts.remove(docId);
            _scheduleDecryptRebuild();
            return _kDecryptKeyError;
          });
      _pendingDecrypts[docId] = pending;
      _decryptCache[docId] = _kDecryptPending;
      return '🔒';
    } catch (e) {
      _dbg('decrypt[$docId]: unexpected error — ${e.runtimeType}');
      _decryptCache[docId] = _kDecryptFailed;
      return '🔒';
    }
  }

  String _decryptOwnMessage(String docId, Map<String, dynamic> data) {
    final cached = _decryptCache[docId];
    if (cached != null && cached != _kDecryptPending) return cached;

    if (cached == _kDecryptPending) {
      return '🔒';
    }

    final msgKeyVersion = data["senderKeyVersion"] as String?;
    if (msgKeyVersion == null) {
      _dbg(
        'decryptOwn[$docId]: no senderKeyVersion; attempting legacy decrypt',
      );
    } else if (_myKeyVersion != null && msgKeyVersion != _myKeyVersion) {
      _dbg(
        'decryptOwn[$docId]: key version mismatch (msg=$msgKeyVersion, loaded=$_myKeyVersion)',
      );
      if (!_decryptCache.containsKey(docId)) {
        _decryptCache[docId] = _kDecryptKeyError;
        _decryptKeyErrorCount++;
      }
      return _kDecryptKeyError;
    }

    final aesKeySenderEncrypted = data["aesKeySender"] as String?;
    if (aesKeySenderEncrypted == null) {
      final fallback = data["text_plain"] as String? ?? "🔒 Encrypted message";
      _decryptCache[docId] = fallback;
      return fallback;
    }

    final privateKey = _getOrParsePrivateKey();
    if (privateKey == null) {
      _dbg('decryptOwn[$docId]: private key not loaded');
      return '🔒';
    }

    try {
      final iv = data["iv"] as String?;
      if (iv == null) {
        _dbg('decryptOwn[$docId]: iv field missing — cannot decrypt');
        _decryptCache[docId] = _kDecryptPending;
        return '🔒';
      }

      if (_pendingDecrypts.containsKey(docId)) return '🔒';

      _dbg(
        'decryptOwn[$docId]: RSA+ AES decrypt now on background isolate (was blocking main thread)',
      );
      final pending = RSAHelper.decrypt(aesKeySenderEncrypted, privateKey)
          .then((aesKey) async {
            final plaintext = await EncryptionHelper.decryptMessage(
              data["text"] as String,
              aesKey,
              iv,
            );
            _decryptCache[docId] = plaintext;
            _pendingDecrypts.remove(docId);
            if (_decryptCache.length > 200) {
              final keysToRemove = _decryptCache.keys
                  .take(_decryptCache.length - 150)
                  .toList();
              keysToRemove.forEach(_decryptCache.remove);
            }
            _scheduleDecryptRebuild();
            return plaintext;
          })
          .catchError((e) {
            _dbg('decryptOwn[$docId]: ${e.runtimeType}');
            if (e is ArgumentError) {
              _decryptCache[docId] = _kDecryptKeyError;
              _decryptKeyErrorCount++;
              _scheduleDecryptRebuild();
            } else {
              _decryptCache[docId] = _kDecryptFailed;
            }
            _pendingDecrypts.remove(docId);
            _scheduleDecryptRebuild();
            return _kDecryptKeyError;
          });
      _pendingDecrypts[docId] = pending;
      _decryptCache[docId] = _kDecryptPending;
      return '🔒';
    } catch (e) {
      _dbg('decryptOwn[$docId]: unexpected error — ${e.runtimeType}');
      _decryptCache[docId] = _kDecryptFailed;
      return '🔒';
    }
  }

void _scheduleDecryptRebuild() {
    if (!mounted) return;
    setState(() {});
  }

  void _preDecryptMessages(List<DocumentSnapshot> docs) {
    final currentDocIds = docs.map((d) => d.id).toSet();
    
    final newDocIds = currentDocIds.difference(_processedDecryptDocIds);
    if (newDocIds.isEmpty) {
      return;
    }
    
    _processedDecryptDocIds = currentDocIds;
    
    int pending = 0;
    for (final doc in docs) {
      if (!newDocIds.contains(doc.id)) continue;
      
      final cached = _decryptCache[doc.id];
      if (cached != null && cached != _kDecryptPending) {
        if (cached == _kDecryptKeyError) {
          continue;
        }
        continue;
      }
      pending++;
      final data = doc.data() as Map<String, dynamic>;
      final isMe = data["senderId"] == currentUser.uid;
      if (isMe) {
        _decryptOwnMessage(doc.id, data);
      } else {
        _decryptCached(doc.id, data);
      }
    }
    if (pending > 0)
      _dbg(
        '_preDecryptMessages: kicked off $pending NEW background decrypts (skipping already-processed)',
      );
  }

  Future<void> _toggleStar(DocumentSnapshot doc) async {
    final data = doc.data() as Map<String, dynamic>;
    final isStarred = data["starred"] ?? false;
    try {
      await doc.reference.update({"starred": !isStarred});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isStarred ? "Removed from starred" : "Added to starred",
            ),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    } catch (e) {
      _dbg('toggleStar: failed — ${e.runtimeType}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Failed to star message"),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _toggleMute() async {
    final colors = AppColors.of(context);
    final roomId = ChatService.getRoomId(currentUser.uid, widget.receiverId);
    try {
      final chatDoc = await FirebaseFirestore.instance
          .collection("chat_rooms")
          .doc(roomId)
          .get();
      final chatData = chatDoc.data() ?? {};
      final isMuted = chatData["muted_${currentUser.uid}"] ?? false;
      await FirebaseFirestore.instance.collection("chat_rooms").doc(roomId).set(
        {"muted_${currentUser.uid}": !isMuted},
        SetOptions(merge: true),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isMuted ? "Notifications unmuted" : "Notifications muted",
            ),
            backgroundColor: colors.accent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    } catch (e) {
      _dbg('toggleMute: failed — ${e.runtimeType}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Failed to toggle mute"),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _enterSelection(DocumentSnapshot doc) {
    setState(() {
      _isSelecting = true;
      _selectedIds.add(doc.id);
      _selectedDocs[doc.id] = doc;
    });
  }

  void _toggleSelection(DocumentSnapshot doc) {
    setState(() {
      if (_selectedIds.contains(doc.id)) {
        _selectedIds.remove(doc.id);
        _selectedDocs.remove(doc.id);
        if (_selectedIds.isEmpty) _isSelecting = false;
      } else {
        _selectedIds.add(doc.id);
        _selectedDocs[doc.id] = doc;
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _isSelecting = false;
      _selectedIds.clear();
      _selectedDocs.clear();
    });
  }

  bool get _canDeleteForEveryone {
    if (_selectedDocs.isEmpty) return false;
    return _selectedDocs.values.every((doc) {
      final data = doc.data() as Map<String, dynamic>;
      return ChatService.canDeleteForEveryone(data, currentUser.uid);
    });
  }

  Future<void> _showClearChatDialog() async {
    final colors = AppColors.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text("Clear Chat?", style: TextStyle(color: colors.primaryText)),
        content: Text(
          "This will clear all messages for you only. "
          "The other person will still see them.",
          style: TextStyle(color: colors.secondaryText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text("Cancel", style: TextStyle(color: colors.accent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Clear", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) await _clearChat();
  }

  Future<void> _clearChat() async {
    final colors = AppColors.of(context);
    final roomId = ChatService.getRoomId(currentUser.uid, widget.receiverId);
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
              SizedBox(width: 12),
              Text("Clearing chat..."),
            ],
          ),
          duration: const Duration(seconds: 30),
          backgroundColor: colors.accent,
          behavior: SnackBarBehavior.floating,
        ),
      );

      await ChatService.clearChat(
        chatRoomId: roomId,
        currentUserId: currentUser.uid,
      );
      _decryptCache.clear();

      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text("Chat cleared successfully"),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    } catch (e) {
      _dbg('clearChat: failed — ${e.runtimeType}');
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Failed to clear chat. Please try again."),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final roomId = ChatService.getRoomId(currentUser.uid, widget.receiverId);

    return Scaffold(
      backgroundColor: colors.screenBg,
      appBar: _buildAppBar(roomId, colors),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _messageStream ?? const Stream.empty(),
              builder: (context, snapshot) {
                if (!_keysReady) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(color: colors.accent),
                        const SizedBox(height: 12),
                        Text(
                          'Preparing secure channel...',
                          style: TextStyle(
                            color: colors.secondaryText,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                if (!snapshot.hasData) {
                  return Center(
                    child: CircularProgressIndicator(color: colors.accent),
                  );
                }

                final docs = snapshot.data!.docs;
                final maxBubbleWidth = MediaQuery.of(context).size.width * 0.75;
                _messageListRebuildCount++;
                _dbg(
                  'MessageList StreamBuilder rebuild #$_messageListRebuildCount, docs=${docs.length}, maxBubbleWidth=${maxBubbleWidth.toStringAsFixed(0)}',
                );

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;

                  // Pre-decrypt all messages in the background (off main isolate)
                  _preDecryptMessages(docs);

                  // Handle new message notification
                  final newCount = docs.length;
                  if (_previousMessageCount != -1 &&
                      newCount > _previousMessageCount) {
                    final visibleDocs = docs.where((doc) {
                      final data = doc.data() as Map<String, dynamic>;
                      final deletedFor = List<String>.from(
                        data["deletedFor"] ?? [],
                      );
                      return !deletedFor.contains(currentUser.uid);
                    }).toList();

                    if (visibleDocs.isNotEmpty) {
                      final latestData =
                          visibleDocs.last.data() as Map<String, dynamic>;
                      if (latestData["senderId"] != currentUser.uid) {
                        _onNewMessageReceived();
                      }
                    }
                  }
                  _previousMessageCount = newCount;
                  ChatService.markMessagesAsDelivered(
                    currentUser.uid,
                    widget.receiverId,
                  ).then((_) => _markSeenIfActive());

                  // Auto-scroll to bottom when new messages arrive
                  if (scrollController.hasClients) {
                    scrollController.jumpTo(
                      scrollController.position.maxScrollExtent,
                    );
                  }
                });

                return ListView.builder(
                  controller: scrollController,
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data() as Map<String, dynamic>;
                    final deletedFor = List<String>.from(
                      data["deletedFor"] ?? [],
                    );
                    if (deletedFor.contains(currentUser.uid)) {
                      return const SizedBox.shrink();
                    }

                    final timestamp = data["timestamp"] as Timestamp?;
                    bool showDate = false;

                    if (index == 0) {
                      showDate = true;
                    } else {
                      final prev =
                          docs[index - 1].data() as Map<String, dynamic>;
                      final prevTime = prev["timestamp"] as Timestamp?;
                      if (timestamp != null && prevTime != null) {
                        final cur = timestamp.toDate();
                        final prv = prevTime.toDate();
                        if (cur.day != prv.day ||
                            cur.month != prv.month ||
                            cur.year != prv.year) {
                          showDate = true;
                        }
                      }
                    }

                    final cachedText = _decryptCache[docs[index].id];
                    final cacheStatus = cachedText == _kDecryptPending
                        ? 'pending'
                        : (cachedText == null ? 'empty' : 'ready');
                    return KeyedSubtree(
                      key: ValueKey('${docs[index].id}_$cacheStatus'),
                      child: Column(
                        children: [
                          if (showDate)
                            Center(
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: colors.inputBg,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  formatDate(timestamp),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.secondaryText,
                                  ),
                                ),
                              ),
                            ),
                          buildMessage(
                            docs[index],
                            index,
                            docs,
                            colors,
                            maxBubbleWidth,
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (_keyError != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Colors.orange.withValues(alpha: 0.15),
              child: Row(
                children: [
                  const Icon(
                    Icons.lock_outline,
                    size: 16,
                    color: Colors.orange,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _keyError!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.orange,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: _loadKeys,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Text(
                        "Retry",
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.orange,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          if (_keysReady && _decryptKeyErrorCount > 2)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Colors.red.withValues(alpha: 0.12),
              child: Row(
                children: [
                  const Icon(Icons.vpn_key_off, size: 16, color: Colors.red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Key mismatch detected (${_decryptKeyErrorCount} errors) — re-authenticate to restore access',
                      style: const TextStyle(fontSize: 12, color: Colors.red),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => AuthService.logout(context),
                    child: const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Text(
                        "Re-login",
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.red,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // ── Receiver key not ready ───────────────────────────────────────
          if (_receiverKeyError != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Colors.blue.withValues(alpha: 0.1),
              child: Row(
                children: [
                  const Icon(
                    Icons.hourglass_empty,
                    size: 16,
                    color: Colors.blue,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _receiverKeyError!,
                      style: const TextStyle(fontSize: 12, color: Colors.blue),
                    ),
                  ),
                ],
              ),
            ),

          // ── Offline banner ───────────────────────────────────────────
          if (!_isOnline)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              color: Colors.grey.withValues(alpha: 0.2),
              child: const Row(
                children: [
                  Icon(Icons.cloud_off, size: 14, color: Colors.grey),
                  SizedBox(width: 6),
                  Text(
                    "You're offline — messages will be queued",
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),

          // ── Reply-to banner ──────────────────────────────────────────
          if (_replyToData != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: colors.inputBg,
              child: Row(
                children: [
                  Container(width: 3, height: 36, color: colors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _replyToData!["senderId"] == currentUser.uid
                              ? "You"
                              : _receiverName,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.accent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _replyToData!["preview"] as String? ?? "",
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.secondaryText,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.close,
                      size: 18,
                      color: colors.secondaryText,
                    ),
                    onPressed: () => setState(() => _replyToData = null),
                  ),
                ],
              ),
            ),

          // ── Edit mode banner ─────────────────────────────────────────
          if (_editingDoc != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: colors.inputBg,
              child: Row(
                children: [
                  Icon(Icons.edit, size: 16, color: colors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Editing message",
                      style: TextStyle(fontSize: 12, color: colors.accent),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.close,
                      size: 18,
                      color: colors.secondaryText,
                    ),
                    onPressed: () => setState(() {
                      _editingDoc = null;
                      controller.clear();
                    }),
                  ),
                ],
              ),
            ),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: colors.appBarBg,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_showEmojiPicker)
                  SizedBox(
                    height: 250,
                    child: EmojiPicker(
                      onEmojiSelected: (category, emoji) {
                        final text = controller.text;
                        final selection = controller.selection;
                        final start = selection.baseOffset >= 0 ? selection.baseOffset : text.length;
                        final end = selection.extentOffset >= 0 ? selection.extentOffset : text.length;
                        final newText = text.replaceRange(start, end, emoji.emoji);
                        controller.text = newText;
                        controller.selection = TextSelection.collapsed(
                          offset: start + emoji.emoji.length,
                        );
                        setState(() => _showEmojiPicker = false);
                      },
                      config: Config(
                        emojiViewConfig: EmojiViewConfig(
                          columns: 7,
                          emojiSizeMax: 28,
                          verticalSpacing: 0,
                          horizontalSpacing: 0,
                          gridPadding: EdgeInsets.zero,
                          backgroundColor:
                              Theme.of(context).brightness == Brightness.dark
                              ? const Color(0xFF1E293B)
                              : const Color(0xFFFFFFFF),
                          recentsLimit: 28,
                          buttonMode: ButtonMode.MATERIAL,
                        ),
                        categoryViewConfig: CategoryViewConfig(
                          backgroundColor:
                              Theme.of(context).brightness == Brightness.dark
                              ? const Color(0xFF1E293B)
                              : const Color(0xFFFFFFFF),
                          indicatorColor: colors.accent,
                          iconColor: colors.secondaryText,
                          iconColorSelected: colors.accent,
                        ),
                        skinToneConfig: SkinToneConfig(
                          dialogBackgroundColor: colors.cardBg,
                          indicatorColor: colors.borderColor,
                        ),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    GestureDetector(
                      onTap: () =>
                          setState(() => _showEmojiPicker = !_showEmojiPicker),
                      child: Icon(
                        _showEmojiPicker
                            ? Icons.keyboard
                            : Icons.emoji_emotions_outlined,
                        color: colors.secondaryText,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: colors.inputBg,
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: TextField(
                          controller: controller,
                          style: TextStyle(color: colors.primaryText),
                          onChanged: (value) {
                            if (!isTyping) {
                              isTyping = true;
                              updateTyping(true);
                            }
                            typingTimer?.cancel();
                            typingTimer = Timer(const Duration(seconds: 2), () {
                              isTyping = false;
                              updateTyping(false);
                            });
                          },
                          decoration: InputDecoration(
                            hintText: "Type a message...",
                            hintStyle: TextStyle(color: colors.hintText),
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.inputBg,
                      ),
                      child: IconButton(
                        icon: Icon(
                          Icons.send,
                          color: _keysReady ? colors.accent : colors.hintText,
                        ),
                        onPressed: _keysReady ? sendMessage : null,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildMessage(
    DocumentSnapshot doc,
    int index,
    List docs,
    AppColors colors,
    double maxBubbleWidth,
  ) {
    final data = doc.data() as Map<String, dynamic>;
    final isMe = data["senderId"] == currentUser.uid;
    final isStarred = data["starred"] ?? false;

    bool isLastInGroup = true;
    if (index < docs.length - 1) {
      final next = docs[index + 1].data() as Map<String, dynamic>;
      if (next["senderId"] == data["senderId"]) isLastInGroup = false;
    }

    final message = isMe
        ? (data["text"] != null ? _decryptOwnMessage(doc.id, data) : "")
        : _decryptCached(doc.id, data);

    if (searchQuery.isNotEmpty &&
        !message.toLowerCase().contains(searchQuery.toLowerCase())) {
      return const SizedBox.shrink();
    }

    final timestamp = data["timestamp"] as Timestamp?;
    final time = timestamp != null
        ? "${timestamp.toDate().hour.toString().padLeft(2, '0')}:"
              "${timestamp.toDate().minute.toString().padLeft(2, '0')}"
        : "";

    final isSelected = _selectedIds.contains(doc.id);

    return GestureDetector(
      onLongPress: () {
        if (_isSelecting) return;
        _showMessageOptions(doc);
      },
      onTap: () {
        if (_isSelecting) _toggleSelection(doc);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        color: isSelected
            ? colors.accent.withValues(alpha: 0.12)
            : Colors.transparent,
        padding: EdgeInsets.only(
          left: isMe ? 0 : (isSelected ? 4 : 0),
          right: isMe ? (isSelected ? 4 : 0) : 0,
        ),
        child: Stack(
          children: [
            Container(
              margin: EdgeInsets.only(
                top: isLastInGroup ? 14 : 4,
                bottom: 2,
                left: isMe ? 50 : (isSelected ? 36 : 10),
                right: isMe ? (isSelected ? 36 : 10) : 50,
              ),
              child: Align(
                alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  constraints: BoxConstraints(maxWidth: maxBubbleWidth),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: isMe ? colors.myBubble : colors.theirBubble,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: isMe
                          ? const Radius.circular(16)
                          : const Radius.circular(4),
                      bottomRight: isMe
                          ? const Radius.circular(4)
                          : const Radius.circular(16),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // ── Reply-to preview ─────────────────────────────
                      if (data["replyTo"] != null) ...[
                        Container(
                          padding: const EdgeInsets.all(8),
                          margin: const EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                            border: Border(
                              left: BorderSide(color: colors.accent, width: 3),
                            ),
                          ),
                          child: Text(
                            (data["replyTo"]["preview"] as String?) ?? "…",
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.secondaryText,
                              fontStyle: FontStyle.italic,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Flexible(
                            child: searchQuery.isNotEmpty
                                ? RichText(
                                    text: _highlightText(
                                      message,
                                      searchQuery,
                                      colors,
                                    ),
                                  )
                                : Text(
                                    message,
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: colors.primaryText,
                                    ),
                                  ),
                          ),
                          if (isStarred) ...[
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.star,
                              size: 14,
                              color: Colors.amber,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            time,
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.secondaryText,
                            ),
                          ),
                          if (data["editedAt"] != null) ...[
                            const SizedBox(width: 4),
                            Text(
                              "edited",
                              style: TextStyle(
                                fontSize: 10,
                                color: colors.hintText,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                          const SizedBox(width: 4),
                          if (isMe) buildStatusIcon(data),
                        ],
                      ),
                      // ── Reactions ────────────────────────────────────
                      if ((data["reactions"] as Map?)?.isNotEmpty == true) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 4,
                          children: (data["reactions"] as Map<String, dynamic>)
                              .entries
                              .map((e) {
                                final count = (e.value as List).length;
                                final myReaction = (e.value as List).contains(
                                  currentUser.uid,
                                );
                                return GestureDetector(
                                  onTap: () async {
                                    final roomId = ChatService.getRoomId(
                                      currentUser.uid,
                                      widget.receiverId,
                                    );
                                    await ChatService.toggleReaction(
                                      chatRoomId: roomId,
                                      messageId: doc.id,
                                      emoji: e.key,
                                      userId: currentUser.uid,
                                    );
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: myReaction
                                          ? colors.accent.withValues(
                                              alpha: 0.15,
                                            )
                                          : colors.inputBg,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: myReaction
                                            ? colors.accent
                                            : colors.borderColor,
                                      ),
                                    ),
                                    child: Text(
                                      "${e.key} $count",
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                );
                              })
                              .toList(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),

            if (_isSelecting)
              Positioned(
                top: 0,
                bottom: 0,
                left: isMe ? null : 0,
                right: isMe ? 0 : null,
                child: Align(
                  alignment: Alignment.center,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: AnimatedScale(
                      scale: _isSelecting ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 150),
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isSelected ? colors.accent : colors.cardBg,
                          border: Border.all(
                            color: isSelected
                                ? colors.accent
                                : colors.borderColor,
                            width: 1.5,
                          ),
                        ),
                        child: isSelected
                            ? const Icon(
                                Icons.check,
                                size: 14,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showMessageOptions(DocumentSnapshot doc) {
    final colors = AppColors.of(context);
    final data = doc.data() as Map<String, dynamic>;
    final isMe = data["senderId"] == currentUser.uid;
    final isStarred = data["starred"] ?? false;
    final roomId = ChatService.getRoomId(currentUser.uid, widget.receiverId);

    showModalBottomSheet(
      context: context,
      backgroundColor: colors.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.borderColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // ── Reaction row ─────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: ['👍', '❤️', '😂', '😮', '😢', '🙏'].map((emoji) {
                  return GestureDetector(
                    onTap: () async {
                      Navigator.pop(context);
                      await ChatService.toggleReaction(
                        chatRoomId: roomId,
                        messageId: doc.id,
                        emoji: emoji,
                        userId: currentUser.uid,
                      );
                    },
                    child: Text(emoji, style: const TextStyle(fontSize: 28)),
                  );
                }).toList(),
              ),
            ),
            const Divider(height: 1),
            // ── Reply ────────────────────────────────────────────
            ListTile(
              leading: Icon(Icons.reply, color: colors.primaryText),
              title: Text("Reply", style: TextStyle(color: colors.primaryText)),
              onTap: () {
                Navigator.pop(context);
                final decrypted = isMe
                    ? _decryptOwnMessage(doc.id, data)
                    : _decryptCached(doc.id, data);
                setState(() {
                  _replyToData = {
                    "messageId": doc.id,
                    "preview": decrypted.length > 80
                        ? '${decrypted.substring(0, 80)}…'
                        : decrypted,
                    "senderId": data["senderId"],
                  };
                });
              },
            ),
            // ── Edit (own messages only) ──────────────────────────
            if (isMe)
              ListTile(
                leading: Icon(Icons.edit_outlined, color: colors.primaryText),
                title: Text(
                  "Edit",
                  style: TextStyle(color: colors.primaryText),
                ),
                onTap: () {
                  Navigator.pop(context);
                  final decrypted = _decryptOwnMessage(doc.id, data);
                  setState(() {
                    _editingDoc = doc;
                    controller.text = decrypted;
                  });
                },
              ),
            ListTile(
              leading: Icon(
                isStarred ? Icons.star_border : Icons.star,
                color: Colors.amber,
              ),
              title: Text(
                isStarred ? "Unstar" : "Star",
                style: const TextStyle(color: Colors.amber),
              ),
              onTap: () {
                Navigator.pop(context);
                _toggleStar(doc);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.check_circle_outline,
                color: colors.primaryText,
              ),
              title: Text(
                "Select",
                style: TextStyle(color: colors.primaryText),
              ),
              onTap: () {
                Navigator.pop(context);
                _enterSelection(doc);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: colors.primaryText),
              title: Text(
                "Delete for me",
                style: TextStyle(color: colors.primaryText),
              ),
              onTap: () async {
                Navigator.pop(context);
                await ChatService.deleteMessages(
                  chatRoomId: roomId,
                  messages: [doc],
                  currentUserId: currentUser.uid,
                  forEveryone: false,
                );
                _decryptCache.remove(doc.id);
              },
            ),
            if (isMe)
              ListTile(
                leading: const Icon(
                  Icons.delete_sweep_outlined,
                  color: Colors.red,
                ),
                title: const Text(
                  "Delete for everyone",
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  await ChatService.deleteMessages(
                    chatRoomId: roomId,
                    messages: [doc],
                    currentUserId: currentUser.uid,
                    forEveryone: true,
                  );
                  _decryptCache.remove(doc.id);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget buildStatusIcon(Map<String, dynamic> message) {
    final colors = AppColors.of(context);
    final status = message['status'] as String? ?? 'sent';
    return switch (status) {
      'seen' => Icon(Icons.done_all, size: 14, color: colors.accent),
      'delivered' => Icon(
        Icons.done_all,
        size: 14,
        color: colors.secondaryText,
      ),
      _ => Icon(Icons.check, size: 14, color: colors.secondaryText),
    };
  }

  TextSpan _highlightText(String text, String query, AppColors colors) {
    _dbg(
      '_highlightText: called with query="$query" (only expected when searching)',
    );
    if (query.isEmpty) {
      return TextSpan(
        text: text,
        style: TextStyle(color: colors.primaryText),
      );
    }
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final start = lowerText.indexOf(lowerQuery);
    if (start == -1) {
      return TextSpan(
        text: text,
        style: TextStyle(color: colors.primaryText),
      );
    }
    return TextSpan(
      children: [
        TextSpan(
          text: text.substring(0, start),
          style: TextStyle(color: colors.primaryText),
        ),
        TextSpan(
          text: text.substring(start, start + query.length),
          style: const TextStyle(
            backgroundColor: Colors.yellow,
            color: Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
        TextSpan(
          text: text.substring(start + query.length),
          style: TextStyle(color: colors.primaryText),
        ),
      ],
    );
  }

  String formatDate(Timestamp? timestamp) {
    if (timestamp == null) return "";
    final date = timestamp.toDate();
    return "${_weekday(date.weekday)}, ${_month(date.month)} ${date.day}";
  }

  String _weekday(int day) => const [
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday",
  ][day - 1];

  String _month(int month) => const [
    "Jan",
    "Feb",
    "March",
    "April",
    "May",
    "June",
    "July",
    "Aug",
    "Sept",
    "Oct",
    "Nov",
    "Dec",
  ][month - 1];

  PreferredSizeWidget _buildAppBar(String roomId, AppColors colors) {
    if (_isSelecting) {
      return AppBar(
        backgroundColor: colors.appBarBg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.close, color: colors.primaryText),
          onPressed: _clearSelection,
        ),
        title: Text(
          "${_selectedIds.length} selected",
          style: TextStyle(
            color: colors.primaryText,
            fontWeight: FontWeight.w500,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.delete_outline, color: colors.primaryText),
            tooltip: "Delete",
            onPressed: _showDeleteSheet,
          ),
          const SizedBox(width: 8),
        ],
      );
    }

    if (isSearching) {
      return AppBar(
        backgroundColor: colors.appBarBg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.primaryText),
          onPressed: () => setState(() {
            isSearching = false;
            searchQuery = "";
            searchController.clear();
          }),
        ),
        title: TextField(
          controller: searchController,
          autofocus: true,
          style: TextStyle(color: colors.primaryText),
          decoration: InputDecoration(
            hintText: "Search messages...",
            hintStyle: TextStyle(color: colors.hintText),
            border: InputBorder.none,
          ),
          onChanged: (value) {
            setState(
              () => searchQuery = InputValidator.sanitizeSearchQuery(value),
            );
          },
        ),
        actions: [
          if (searchQuery.isNotEmpty)
            IconButton(
              icon: Icon(Icons.close, color: colors.primaryText),
              onPressed: () => setState(() {
                searchQuery = "";
                searchController.clear();
              }),
            ),
        ],
      );
    }

    return AppBar(
      backgroundColor: colors.appBarBg,
      elevation: 0,
      titleSpacing: 0,
      title: StreamBuilder<DocumentSnapshot>(
        stream: _roomExists
            ? FirebaseFirestore.instance
                  .collection("chat_rooms")
                  .doc(roomId)
                  .snapshots()
            : const Stream.empty(),
        builder: (context, chatSnap) {
          bool isTypingNow = false;
          bool isMuted = false;

          if (chatSnap.hasData && chatSnap.data!.exists) {
            final chatData =
                chatSnap.data!.data() as Map<String, dynamic>? ?? {};
            isTypingNow = chatData["typing_${widget.receiverId}"] ?? false;
            isMuted = chatData["muted_${currentUser.uid}"] ?? false;
          }

          return Row(
            children: [
              const SizedBox(width: 8),
              CircleAvatar(
                radius: 18,
                backgroundColor: colors.accent,
                child: Text(
                  getInitials(_receiverName),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _receiverName,
                            style: TextStyle(
                              color: colors.primaryText,
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isMuted) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.notifications_off,
                            size: 14,
                            color: Colors.grey,
                          ),
                        ],
                      ],
                    ),
                    Text(
                      isTypingNow ? "typing..." : "",
                      style: TextStyle(fontSize: 12, color: colors.accent),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.sports_esports, color: colors.primaryText),
                tooltip: "Play game",
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => GameScreen(
                        roomId: roomId,
                        opponentId: widget.receiverId,
                        opponentName: _receiverName,
                      ),
                    ),
                  );
                },
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: colors.primaryText),
                color: colors.cardBg,
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: "profile",
                    child: Text(
                      "View profile",
                      style: TextStyle(color: colors.primaryText),
                    ),
                  ),
                  PopupMenuItem(
                    value: "search",
                    child: Text(
                      "Search",
                      style: TextStyle(color: colors.primaryText),
                    ),
                  ),
                  PopupMenuItem(
                    value: "mute",
                    child: Text(
                      isMuted ? "Unmute notifications" : "Mute notifications",
                      style: TextStyle(color: colors.primaryText),
                    ),
                  ),
                  PopupMenuItem(
                    value: "starred",
                    child: Text(
                      "Starred messages",
                      style: TextStyle(color: colors.primaryText),
                    ),
                  ),
                  const PopupMenuItem(
                    value: "clear",
                    child: Text(
                      "Clear chat",
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
                onSelected: (value) {
                  switch (value) {
                    case "search":
                      setState(() => isSearching = true);
                    case "profile":
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              ProfileScreen(userId: widget.receiverId),
                        ),
                      );
                    case "clear":
                      _showClearChatDialog();
                    case "mute":
                      _toggleMute();
                    case "starred":
                      _showStarredMessages();
                  }
                },
              ),
              const SizedBox(width: 8),
            ],
          );
        },
      ),
    );
  }

  void _showDeleteSheet() {
    final colors = AppColors.of(context);
    final roomId = ChatService.getRoomId(currentUser.uid, widget.receiverId);
    final count = _selectedIds.length;

    final allStarred = _selectedDocs.values.every((doc) {
      final data = doc.data() as Map<String, dynamic>;
      return data["starred"] ?? false;
    });

    showModalBottomSheet(
      context: context,
      backgroundColor: colors.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.borderColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                "$count message${count == 1 ? '' : 's'} selected",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: colors.primaryText,
                ),
              ),
            ),
            Divider(height: 1, color: colors.divider),
            ListTile(
              leading: Icon(
                allStarred ? Icons.star_border : Icons.star,
                color: Colors.amber,
              ),
              title: Text(
                allStarred ? "Unstar" : "Star",
                style: const TextStyle(color: Colors.amber),
              ),
              subtitle: Text(
                allStarred ? "Remove from starred" : "Add to starred",
                style: TextStyle(color: colors.secondaryText),
              ),
              onTap: () async {
                Navigator.pop(context);
                final batch = FirebaseFirestore.instance.batch();
                for (final doc in _selectedDocs.values) {
                  batch.update(doc.reference, {"starred": !allStarred});
                }
                await batch.commit();
                _clearSelection();
              },
            ),
            if (_canDeleteForEveryone)
              ListTile(
                leading: const Icon(
                  Icons.delete_sweep_outlined,
                  color: Colors.red,
                ),
                title: const Text(
                  "Delete for everyone",
                  style: TextStyle(color: Colors.red),
                ),
                subtitle: Text(
                  "Removes messages for both sides",
                  style: TextStyle(color: colors.secondaryText),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  await ChatService.deleteMessages(
                    chatRoomId: roomId,
                    messages: _selectedDocs.values.toList(),
                    currentUserId: currentUser.uid,
                    forEveryone: true,
                  );
                  for (final id in _selectedIds) {
                    _decryptCache.remove(id);
                  }
                  _clearSelection();
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: colors.primaryText),
              title: Text(
                "Delete for me",
                style: TextStyle(color: colors.primaryText),
              ),
              subtitle: Text(
                "Only you won't see these messages",
                style: TextStyle(color: colors.secondaryText),
              ),
              onTap: () async {
                Navigator.pop(context);
                await ChatService.deleteMessages(
                  chatRoomId: roomId,
                  messages: _selectedDocs.values.toList(),
                  currentUserId: currentUser.uid,
                  forEveryone: false,
                );
                for (final id in _selectedIds) {
                  _decryptCache.remove(id);
                }
                _clearSelection();
              },
            ),
            ListTile(
              leading: Icon(Icons.close, color: colors.secondaryText),
              title: Text(
                "Cancel",
                style: TextStyle(color: colors.secondaryText),
              ),
              onTap: () => Navigator.pop(context),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showStarredMessages() {
    final colors = AppColors.of(context);
    final roomId = ChatService.getRoomId(currentUser.uid, widget.receiverId);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: colors.screenBg,
          appBar: AppBar(
            backgroundColor: colors.appBarBg,
            elevation: 0,
            leading: IconButton(
              icon: Icon(Icons.arrow_back, color: colors.primaryText),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(
              "Starred Messages",
              style: TextStyle(
                color: colors.primaryText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          body: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection("chat_rooms")
                .doc(roomId)
                .collection("messages")
                .where("starred", isEqualTo: true)
                .orderBy("timestamp", descending: true)
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData || !_keysReady) {
                return Center(
                  child: CircularProgressIndicator(color: colors.accent),
                );
              }

              final starredDocs = snapshot.data!.docs;
              if (starredDocs.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star_border, size: 64, color: colors.hintText),
                      const SizedBox(height: 16),
                      Text(
                        "No starred messages",
                        style: TextStyle(
                          fontSize: 16,
                          color: colors.secondaryText,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "Star important messages to find them easily",
                        style: TextStyle(fontSize: 13, color: colors.hintText),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: starredDocs.length,
                itemBuilder: (context, index) {
                  final doc = starredDocs[index];
                  final data = doc.data() as Map<String, dynamic>;
                  final isMe = data["senderId"] == currentUser.uid;

                  final message = isMe
                      ? _decryptOwnMessage(doc.id, data)
                      : _decryptCached(doc.id, data);

                  final timestamp = data["timestamp"] as Timestamp?;
                  final dateStr = timestamp != null
                      ? "${timestamp.toDate().day}/"
                            "${timestamp.toDate().month}/"
                            "${timestamp.toDate().year}"
                      : "";
                  final timeStr = timestamp != null
                      ? "${timestamp.toDate().hour.toString().padLeft(2, '0')}:"
                            "${timestamp.toDate().minute.toString().padLeft(2, '0')}"
                      : "";

                  return Container(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.cardBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.borderColor),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                message,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: colors.primaryText,
                                ),
                              ),
                            ),
                            GestureDetector(
                              onTap: () => _toggleStar(doc),
                              child: const Icon(
                                Icons.star,
                                size: 18,
                                color: Colors.amber,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              isMe ? "You" : _receiverName,
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.accent,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              "$dateStr • $timeStr",
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.secondaryText,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

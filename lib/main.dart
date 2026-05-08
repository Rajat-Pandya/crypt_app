import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/login_screen.dart';
import 'screens/verification_screen.dart';
import 'screens/chat_list_screen.dart';
import 'screens/chat_screen.dart';
import 'services/session_manager.dart';
import 'services/auth_service.dart';
import 'config/app_config.dart';
import 'utils/game_state.dart';

// ── Global theme notifier ──────────────────────────────────────────────────
final themeNotifier = ValueNotifier<ThemeMode>(ThemeMode.light);

// ── Global navigator key ───────────────────────────────────────────────────
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// ── Internal debug helper ──────────────────────────────────────────────────
void _dbg(String message) {
  assert(() {
    debugPrint('[Main] $message');
    return true;
  }());
}

void _setupErrorHandling() {
  FlutterError.onError = (details) {
    if (kDebugMode) {
      FlutterError.presentError(details);
    }
    _dbg('FlutterError: ${details.exception}');
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    _dbg('PlatformError: $error');
    return true;
  };
}
// ────────────────────────────────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _setupErrorHandling();

  // ── Critical: Firebase must initialize before runApp() ──────────────────
  await Firebase.initializeApp();

  // ── App Check ─────────────────────────────────────────────────────────
  // Defer AppCheck activation to avoid blocking startup.
  // App Check protects Firestore but the app can function without it temporarily.
  Future.microtask(() async {
    try {
      await FirebaseAppCheck.instance.activate(
        androidProvider: kDebugMode
            ? AndroidProvider.debug
            : AndroidProvider.playIntegrity,
        appleProvider: kDebugMode
            ? AppleProvider.debug
            : AppleProvider.appAttest,
      );
      _dbg('App Check activated');
    } catch (e) {
      _dbg('App Check activation failed — ${e.runtimeType} (non-critical)');
    }
  });

  // ── Firestore offline persistence ──────────────────────────────────────
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: 50 * 1024 * 1024, // 50 MB — sufficient for chat + game data
  );

  // ── Theme (deferred, non-blocking) ───────────────────────────────────
  // SharedPreferences is a file read (~50ms) — acceptable on cold start.
  final prefs = await SharedPreferences.getInstance();
  final isDark = prefs.getBool("darkMode") ?? false;
  themeNotifier.value = isDark ? ThemeMode.dark : ThemeMode.light;

  // ── OneSignal deferred to background ────────────────────────────────────
  // CRITICAL FIX: OneSignal.initialize() takes 1-6 seconds on first run
  // (network call to OneSignal servers + device token generation).
  // Previously this blocked runApp() entirely — causing the 6058ms ANR.
  // Now: app renders first, user sees the UI while OneSignal initializes.
  Future.microtask(() async {
    if (AppConfig.oneSignalAppId.isEmpty) {
      _dbg('OneSignal skipped: ONESIGNAL_APP_ID not set');
      return;
    }

    _dbg('OneSignal: initializing in background...');
    try {
      OneSignal.initialize(AppConfig.oneSignalAppId);
      _dbg('OneSignal: initialized');

      OneSignal.Notifications.addForegroundWillDisplayListener((event) {
        event.notification.display();
      });

      OneSignal.Notifications.addClickListener((event) {
        _dbg('notification clicked');
        final data = event.notification.additionalData;
        final senderId = data?['senderId'] as String?;
        if (senderId != null) {
          navigatorKey.currentState?.push(
            MaterialPageRoute(builder: (_) => ChatScreen(receiverId: senderId)),
          );
        }
      });

      // Lazily request permission after the app is mounted and visible.
      // Do NOT await — OS can kill the cold-start activity when the
      // system dialog moves the app to background.
      OneSignal.Notifications.requestPermission(true);
    } catch (e) {
      _dbg('OneSignal init failed — ${e.runtimeType} (non-critical)');
    }
  });

  runApp(const CryptApp());
}

// ── App ────────────────────────────────────────────────────────────────────

class CryptApp extends StatelessWidget {
  const CryptApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          scaffoldMessengerKey: SessionManager.scaffoldKey,
          themeMode: mode,

          theme: ThemeData(
            brightness: Brightness.light,
            colorSchemeSeed: const Color(0xFF3B82F6),
            scaffoldBackgroundColor: const Color(0xFFF7F7F7),
            useMaterial3: true,
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFFF5F5F5),
              elevation: 0,
              iconTheme: IconThemeData(color: Colors.black),
              titleTextStyle: TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
            extensions: const [
              AppColors(
                screenBg: Color(0xFFF7F7F7),
                appBarBg: Color(0xFFF5F5F5),
                cardBg: Color(0xFFFFFFFF),
                inputBg: Color(0xFFEDEDED),
                primaryText: Color(0xFF111827),
                secondaryText: Color(0xFF6B7280),
                hintText: Color(0xFF9CA3AF),
                myBubble: Color(0xFFEFF6FF),
                theirBubble: Color(0xFFFFFFFF),
                myBubbleText: Color(0xFF1E40AF),
                theirBubbleText: Color(0xFF111827),
                borderColor: Color(0xFFE5E7EB),
                accent: Color(0xFF3B82F6),
                onlineGreen: Color(0xFF22C55E),
                divider: Color(0xFFE5E7EB),
              ),
            ],
          ),

          darkTheme: ThemeData(
            brightness: Brightness.dark,
            colorSchemeSeed: const Color(0xFF3B82F6),
            scaffoldBackgroundColor: const Color(0xFF0F172A),
            useMaterial3: true,
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFF1E293B),
              elevation: 0,
              iconTheme: IconThemeData(color: Color(0xFFF1F5F9)),
              titleTextStyle: TextStyle(
                color: Color(0xFFF1F5F9),
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
            extensions: const [
              AppColors(
                screenBg: Color(0xFF0F172A),
                appBarBg: Color(0xFF1E293B),
                cardBg: Color(0xFF1E293B),
                inputBg: Color(0xFF334155),
                primaryText: Color(0xFFF1F5F9),
                secondaryText: Color(0xFF94A3B8),
                hintText: Color(0xFF64748B),
                myBubble: Color(0xFF1D3461),
                theirBubble: Color(0xFF1E293B),
                myBubbleText: Color(0xFFBFDBFE),
                theirBubbleText: Color(0xFFF1F5F9),
                borderColor: Color(0xFF334155),
                accent: Color(0xFF3B82F6),
                onlineGreen: Color(0xFF22C55E),
                divider: Color(0xFF334155),
              ),
            ],
          ),

          home: GestureDetector(
            onTap: () => SessionManager.recordActivity(),
            onPanDown: (_) => SessionManager.recordActivity(),
            child: const AuthWrapper(),
          ),
        );
      },
    );
  }
}

// ── AppColors Theme Extension ──────────────────────────────────────────────

@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.screenBg,
    required this.appBarBg,
    required this.cardBg,
    required this.inputBg,
    required this.primaryText,
    required this.secondaryText,
    required this.hintText,
    required this.myBubble,
    required this.theirBubble,
    required this.myBubbleText,
    required this.theirBubbleText,
    required this.borderColor,
    required this.accent,
    required this.onlineGreen,
    required this.divider,
  });

  final Color screenBg;
  final Color appBarBg;
  final Color cardBg;
  final Color inputBg;
  final Color primaryText;
  final Color secondaryText;
  final Color hintText;
  final Color myBubble;
  final Color theirBubble;
  final Color myBubbleText;
  final Color theirBubbleText;
  final Color borderColor;
  final Color accent;
  final Color onlineGreen;
  final Color divider;

  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>()!;

  @override
  AppColors copyWith({
    Color? screenBg,
    Color? appBarBg,
    Color? cardBg,
    Color? inputBg,
    Color? primaryText,
    Color? secondaryText,
    Color? hintText,
    Color? myBubble,
    Color? theirBubble,
    Color? myBubbleText,
    Color? theirBubbleText,
    Color? borderColor,
    Color? accent,
    Color? onlineGreen,
    Color? divider,
  }) {
    return AppColors(
      screenBg: screenBg ?? this.screenBg,
      appBarBg: appBarBg ?? this.appBarBg,
      cardBg: cardBg ?? this.cardBg,
      inputBg: inputBg ?? this.inputBg,
      primaryText: primaryText ?? this.primaryText,
      secondaryText: secondaryText ?? this.secondaryText,
      hintText: hintText ?? this.hintText,
      myBubble: myBubble ?? this.myBubble,
      theirBubble: theirBubble ?? this.theirBubble,
      myBubbleText: myBubbleText ?? this.myBubbleText,
      theirBubbleText: theirBubbleText ?? this.theirBubbleText,
      borderColor: borderColor ?? this.borderColor,
      accent: accent ?? this.accent,
      onlineGreen: onlineGreen ?? this.onlineGreen,
      divider: divider ?? this.divider,
    );
  }

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      screenBg: Color.lerp(screenBg, other.screenBg, t)!,
      appBarBg: Color.lerp(appBarBg, other.appBarBg, t)!,
      cardBg: Color.lerp(cardBg, other.cardBg, t)!,
      inputBg: Color.lerp(inputBg, other.inputBg, t)!,
      primaryText: Color.lerp(primaryText, other.primaryText, t)!,
      secondaryText: Color.lerp(secondaryText, other.secondaryText, t)!,
      hintText: Color.lerp(hintText, other.hintText, t)!,
      myBubble: Color.lerp(myBubble, other.myBubble, t)!,
      theirBubble: Color.lerp(theirBubble, other.theirBubble, t)!,
      myBubbleText: Color.lerp(myBubbleText, other.myBubbleText, t)!,
      theirBubbleText: Color.lerp(theirBubbleText, other.theirBubbleText, t)!,
      borderColor: Color.lerp(borderColor, other.borderColor, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onlineGreen: Color.lerp(onlineGreen, other.onlineGreen, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
    );
  }
}

// ── Auth Wrapper ───────────────────────────────────────────────────────────

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> with WidgetsBindingObserver {
  Timer? onlineTimer;
  Timer? _encryptionRetryTimer;

  bool _encryptionReady = false;
  bool _encryptionRunning = false;
  bool _verifyAttempted = false;
  bool _oneSignalSetupDone = false;
  String? _currentSetupUid;

  DateTime? _lastSaveTime;
  bool _saveUserDataPending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dbg('AuthWrapper initialized');

    OneSignal.User.pushSubscription.addObserver((state) async {
      final playerId = state.current.id;
      final optedIn = state.current.optedIn;
      _dbg(
        'OneSignal subscription changed: id=${playerId != null}, optedIn=$optedIn',
      );
      if (playerId != null && optedIn == true) {
        await saveUserData(playerId: playerId);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final playerId = OneSignal.User.pushSubscription.id;
      if (playerId != null) {
        saveUserData(playerId: playerId);
      }
    });
  }

  Future<void> saveUserData({String? playerId, bool? isOnline}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (_saveUserDataPending) {
      _dbg('saveUserData: skipped — pending write in progress');
      return;
    }

    if (GameState.isPlaying) {
      _dbg('saveUserData: skipped — game active');
      return;
    }

    if (playerId == null) {
      final now = DateTime.now();
      if (_lastSaveTime != null &&
          now.difference(_lastSaveTime!).inSeconds < 60) {
        return;
      }
    }

    _saveUserDataPending = true;
    await Future.delayed(const Duration(milliseconds: 300));

    try {
      _dbg('saveUserData: writing Firestore');

      final data = <String, dynamic>{"lastSeen": FieldValue.serverTimestamp()};
      if (playerId != null) data["oneSignalPlayerId"] = playerId;
      if (isOnline != null) data["isOnline"] = isOnline;

      await FirebaseFirestore.instance
          .collection("users")
          .doc(user.uid)
          .set(data, SetOptions(merge: true));
      _dbg('saveUserData: complete');

      _lastSaveTime = DateTime.now();
    } catch (e) {
      _dbg('saveUserData: failed — ${e.runtimeType}');
    } finally {
      _saveUserDataPending = false;
    }
  }

  Future<void> _setupOneSignalUser(User firebaseUser) async {
    if (_currentSetupUid == firebaseUser.uid) return;
    _currentSetupUid = firebaseUser.uid;

    _dbg('OneSignal login: uid=${firebaseUser.uid}');

    try {
      await OneSignal.login(firebaseUser.uid);
      _dbg('OneSignal login: success');

      final subscriptionId = OneSignal.User.pushSubscription.id;
      final optedIn = OneSignal.User.pushSubscription.optedIn;
      _dbg('OneSignal subscriptionId: $subscriptionId, optedIn: $optedIn');
    } catch (e, st) {
      _dbg('OneSignal login failed: ${e.runtimeType}');
      if (kDebugMode) debugPrint('[Main] OneSignal login error: $st');
    }
  }

  Future<void> _verifyEncryptionReady(User user) async {
    // Guard: never run twice simultaneously
    if (_encryptionRunning || _verifyAttempted) return;
    _encryptionRunning = true;
    _verifyAttempted = true;

    _dbg('_verifyEncryptionReady: starting');

    // Wait for login to finish (RSA key generation happens in login())
    if (AuthService.loginInProgress) {
      _dbg('_verifyEncryptionReady: login in progress — deferring');
      _encryptionRetryTimer ??= Timer(const Duration(milliseconds: 300), () {
        _encryptionRetryTimer = null;
        if (mounted && !_encryptionReady) {
          _encryptionRunning = false;
          _verifyAttempted = false;
          _verifyEncryptionReady(user);
        }
      });
      return;
    }

    try {
      final setupDone = await AuthService.storage.read(
        key: 'encryption_setup_done',
      );

      _dbg('_verifyEncryptionReady: setupDone=$setupDone');

      if (setupDone == 'true') {
        _dbg('_verifyEncryptionReady: already done');
        // Always check/retry public key upload (self-healing)
        await AuthService.retryPublicKeyUpload(user);
        if (mounted) {
          setState(() {
            _encryptionReady = true;
            _encryptionRunning = false;
          });
        }
        return;
      }

      // Flag missing — check if key exists as fallback
      final keyExists = await AuthService.storage.read(key: 'private_key');
      _dbg('_verifyEncryptionReady: keyExists=${keyExists != null}');

      if (keyExists != null) {
        await AuthService.storage.write(
          key: 'encryption_setup_done',
          value: 'true',
        );
        if (mounted) {
          setState(() {
            _encryptionReady = true;
            _encryptionRunning = false;
          });
        }
        return;
      }

      // No key found — likely reinstall with cleared secure storage.
      // Sign out and let user re-login to restore key from backup.
      _dbg('_verifyEncryptionReady: no key — signing out');
      if (mounted) setState(() => _encryptionRunning = false);
      await FirebaseAuth.instance.signOut();
    } catch (e, st) {
      _dbg('_verifyEncryptionReady: failed — ${e.runtimeType}');
      if (kDebugMode) debugPrint('[Main] _verifyEncryptionReady stack: $st');
      if (mounted) {
        setState(() {
          _encryptionRunning = false;
          _verifyAttempted = false; // allow retry
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _dbg('lifecycle: ${state.name}');
    if (state == AppLifecycleState.resumed) {
      saveUserData(isOnline: true);
    } else {
      saveUserData(isOnline: false);
    }
  }

  @override
  void dispose() {
    onlineTimer?.cancel();
    _encryptionRetryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    OneSignal.logout();
    super.dispose();
  }

  Widget _buildLoadingScreen(String message) {
    return Scaffold(
      backgroundColor: AppColors.of(context).screenBg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppColors.of(context).accent),
            const SizedBox(height: 16),
            Text(
              message,
              style: TextStyle(
                color: AppColors.of(context).secondaryText,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: Firebase.apps.isEmpty
          ? const Stream<User?>.empty()
          : FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (Firebase.apps.isEmpty) {
          return const LoginScreen();
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildLoadingScreen("Loading...");
        }

        if (snapshot.hasData) {
          final user = snapshot.data!;
          _dbg('auth: user present, verified=${user.emailVerified}');

          if (!_oneSignalSetupDone) {
            _oneSignalSetupDone = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _setupOneSignalUser(user);
            });
          }

          if (!user.emailVerified) {
            _dbg('showing verification screen');
            SessionManager.stopMonitoring();
            onlineTimer?.cancel();
            onlineTimer = null;
            _encryptionReady = false;
            _encryptionRunning = false;
            _verifyAttempted = false;
            return VerificationScreen(user: user);
          }

          if (!_encryptionReady && !_encryptionRunning && !_verifyAttempted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _verifyEncryptionReady(user);
            });
            return _buildLoadingScreen("Verifying encryption...");
          }

          if (_encryptionRunning) {
            return _buildLoadingScreen("Verifying encryption...");
          }

          SessionManager.startMonitoring();

          if (onlineTimer == null || !onlineTimer!.isActive) {
            onlineTimer = Timer.periodic(const Duration(seconds: 30), (_) {
              final currentUser = FirebaseAuth.instance.currentUser;
              if (currentUser != null) {
                saveUserData(isOnline: true);
                AuthService.storage
                    .read(key: AuthService.publicKeyPendingKey)
                    .then((pubKeyPending) {
                      if (pubKeyPending == 'true') {
                        AuthService.retryPublicKeyUpload(currentUser);
                      }
                    });
              } else {
                onlineTimer?.cancel();
                onlineTimer = null;
              }
            });
          }

          return const ChatListScreen();
        }

        _dbg('auth: no user');
        SessionManager.stopMonitoring();
        onlineTimer?.cancel();
        onlineTimer = null;
        _encryptionReady = false;
        _encryptionRunning = false;
        _verifyAttempted = false;
        _encryptionRetryTimer?.cancel();
        _encryptionRetryTimer = null;
        _oneSignalSetupDone = false;
        _currentSetupUid = null;
        return const LoginScreen();
      },
    );
  }
}

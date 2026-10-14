import 'dart:async';
import 'dart:ui';

import 'package:crypt_app/services/security_hardening_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'screens/login_screen.dart';
import 'screens/verification_screen.dart';
import 'screens/chat_list_screen.dart';
import 'screens/chat_screen_wrapper.dart';
import 'screens/splash_screen.dart';
import 'services/session_lifecycle_manager.dart';
import 'services/auth_service.dart';
import 'services/device_service.dart';
import 'services/key_mismatch_manager.dart';
import 'services/secure_chat_service.dart';
import 'services/chat_util_service.dart';
import 'services/startup_task_scheduler.dart';
import 'services/telemetry_service.dart';
import 'services/encryption_startup_service.dart';
import 'services/encryption_startup_service.dart' as enc show EncryptionStartupState;
import 'services/presence_service.dart';
import 'config/app_config.dart';
import 'cache/cache_service.dart';
import 'blocs/bloc_observer.dart';

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

// Error handling setup
void _setupErrorHandling() {
  FlutterError.onError = (details) {
    debugPrint('[ERROR] ════════════════════════════════════════════════════════════');
    debugPrint('[ERROR] FlutterError caught!');
    debugPrint('[ERROR] Exception: ${details.exception}');
    debugPrint('[ERROR] Stack: ${details.stack}');
    debugPrint('[ERROR] Library: ${details.library}');
    debugPrint('[ERROR] Context: ${details.context}');
    debugPrint('[ERROR] ════════════════════════════════════════════════════════════');
    if (kDebugMode) {
      FlutterError.presentError(details);
    }
    _dbg('FlutterError: ${details.exception}');
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[ERROR] PlatformDispatcher error: $error');
    debugPrint('[ERROR] Stack trace: $stack');
    return true;
  };
  
  // Catch async zone errors
  runZonedGuarded(() {}, (error, stack) {
    debugPrint('[ERROR] Uncaught async error: $error');
    debugPrint('[ERROR] Stack trace: $stack');
  });
}

// ── Startup Initialization Manager ─────────────────────────────────────────
/// 
/// Handles progressive initialization to avoid blocking UI thread.
/// 
/// Priority levels:
/// - Critical: Must complete before first frame (Firebase, HydratedBloc)
/// - High: Should complete quickly after first frame (App Check, theme)
/// - Medium: Can complete in background (Cache, OneSignal)
/// - Low: Deferred until user interaction (notifications, etc)
class _StartupInitializer {
  static bool _initialized = false;
  
  /// Initialize in phases to avoid blocking UI
  static Future<void> initialize() async {
    if (_initialized) return;
    
    // Phase 1: Critical - must complete before runApp
    await _initializeCritical();
    
    // Mark critical initialization complete
    _initialized = true;
    
    // Phase 2: High priority - runs immediately after first frame
    // Using scheduleMicrotask ensures it runs after current event loop
    scheduleMicrotask(_initializeHighPriority);
    
    // Phase 3: Medium priority - runs after high priority completes
    scheduleMicrotask(_initializeMediumPriority);
    
    // Phase 4: Low priority - runs when idle
    await Future.delayed(const Duration(milliseconds: 100));
    _initializeLowPriority();
  }
  
  /// Critical initialization - blocks first frame
  static Future<void> _initializeCritical() async {
    WidgetsFlutterBinding.ensureInitialized();
    
    // Set preferred orientations early to prevent rotation jank
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    
    _setupErrorHandling();
    
    // HydratedBloc storage - must be ready before any Bloc is used
    HydratedBloc.storage = await HydratedStorage.build(
      storageDirectory: kIsWeb
          ? HydratedStorage.webStorageDirectory
          : await getTemporaryDirectory(),
    );
    
    // Activate BLoC observer for event/error logging
    // This enables debug logging for all BLoC events, state changes, and errors
    Bloc.observer = CryptBlocObserver(
      enableLogs: kDebugMode,
      enableAnalytics: AppConfig.isProduction,
    );
    _dbg('BLoC observer activated');
    
    // Firebase is the minimum required for the app to function
    await Firebase.initializeApp();
    
    // Telemetry - crash reporting and metrics
    await TelemetryService().initialize();
    
    // Critical Firestore settings - needed for offline functionality
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: 50 * 1024 * 1024, // 50 MB
    );
    
    // CRITICAL: CacheService MUST be initialized before any repository
    // Repositories access Hive.box() which requires boxes to be open
    await CacheService.initialize().catchError((e) {
      _dbg('[CACHE] CRITICAL: Cache initialization failed: $e');
    });
    
    _dbg('[CACHE] CacheService initialized in critical phase');
  }
  
  /// High priority - runs right after first frame
  static Future<void> _initializeHighPriority() async {
    try {
      // App Check activation - protects Firestore but non-blocking
      await _activateAppCheck();
      
      // Theme loading - fast, local operation
      await _loadTheme();
      
      // Log ChatService configuration (includes push notification config)
      ChatUtilService.initialize();
      
      // DEFER: Security hardening to low priority
      // This is heavy (device checks, replay protection init) and not needed immediately
      StartupTaskScheduler.register(
        name: 'security_hardening_init',
        priority: StartupTaskPriority.low,
        task: () async {
          _dbg('[STARTUP] Starting SecurityHardening initialization');
          await SecurityHardeningService().initialize();
          _dbg('[STARTUP] SecurityHardening initialized');
        },
      );
      
    } catch (e) {
      _dbg('High priority init failed: $e');
    }
  }
  
  /// Medium priority - background initialization
  static Future<void> _initializeMediumPriority() async {
    try {
      // Session encryption manager - non-blocking
      await KeyMismatchManager.initialize().catchError((e) {
        _dbg('[STARTUP] Session encryption init failed (non-critical)');
      });
      
      // CacheService already initialized in critical phase
      // Just clear old cache here
      await CacheService.clearOldCache(const Duration(days: 7)).catchError((e) {
        _dbg('[CACHE] Clear old cache failed: $e');
      });
      
      _dbg('[STARTUP] Medium priority init complete');
    } catch (e) {
      _dbg('[STARTUP] Medium priority init failed: $e');
    }
  }
  
  /// Low priority - deferred until app is idle
  static Future<void> _initializeLowPriority() async {
    try {
      // OneSignal initialization - can be slow (network calls)
      await _initializeOneSignal();
      
      _dbg('Low priority init complete');
    } catch (e) {
      _dbg('Low priority init failed: $e');
    }
  }
  
  /// App Check activation state to prevent duplicate attempts
  static bool _appCheckActivated = false;
  
  /// Activate App Check with proper provider selection
  /// 
  /// SECURITY: Uses environment-based PROD flag to determine provider.
  /// - Production builds: Play Integrity / App Attest
  /// - Development builds: Debug providers
  /// 
  /// ⚠️ CRITICAL: Always build production releases with:
  ///   flutter build apk --dart-define=PROD=true
  static DateTime? _lastAppCheckAttempt;
  static const Duration _minAppCheckInterval = Duration(seconds: 30);
  
  /// Activate Firebase App Check with platform-specific providers.
  /// 
  /// Production builds:
  /// - Android: Play Integrity API
  /// - iOS: App Attest
  /// 
  /// Development builds:
  /// - Debug providers with rate limiting to prevent "Too many attempts"
  /// 
  /// ⚠️ CRITICAL: Always build production releases with:
  ///   flutter build apk --dart-define=PROD=true
  static Future<void> _activateAppCheck() async {
    // Prevent duplicate activation attempts
    if (_appCheckActivated) {
      _dbg('[APP_CHECK] Already activated, skipping');
      return;
    }
    
    // Rate limit App Check activation attempts to prevent "Too many attempts"
    if (_lastAppCheckAttempt != null) {
      final timeSinceLastAttempt = DateTime.now().difference(_lastAppCheckAttempt!);
      if (timeSinceLastAttempt < _minAppCheckInterval) {
        _dbg('[APP_CHECK] Rate limited - last attempt was ${timeSinceLastAttempt.inSeconds}s ago');
        return;
      }
    }
    _lastAppCheckAttempt = DateTime.now();
    _appCheckActivated = true;
    
    try {
      // Determine provider based on environment configuration
      final androidProvider = AppConfig.useProductionAppCheck
          ? AndroidProvider.playIntegrity
          : AndroidProvider.debug;
      final appleProvider = AppConfig.useProductionAppCheck
          ? AppleProvider.appAttest
          : AppleProvider.debug;
      
      _dbg('[APP_CHECK] Activating - Mode: ${AppConfig.isProduction ? "PRODUCTION" : "DEVELOPMENT"}');
      
      await FirebaseAppCheck.instance.activate(
        androidProvider: androidProvider,
        appleProvider: appleProvider,
      );
      
      // In debug mode, set the token manually to avoid spam
      if (!AppConfig.isProduction) {
        _dbg('[APP_CHECK] Debug mode - token acquisition may take a moment');
      }
      
      _dbg('[APP_CHECK] Activated successfully');
      
    } on FirebaseException catch (e) {
      // Handle specific Firebase errors
      if (e.code == 'too-many-requests') {
        _dbg('[APP_CHECK] ⚠️ Rate limited by Firebase - too many attempts');
        _dbg('[APP_CHECK] Will retry on next app launch');
      } else if (e.code == 'app-check-token-fetch-failed') {
        _dbg('[APP_CHECK] ⚠️ Token fetch failed - device may not support attestation');
      } else if (e.code == 'unimplemented') {
        _dbg('[APP_CHECK] ⚠️ App Check not implemented for this platform');
      } else {
        _dbg('[APP_CHECK] ⚠️ Activation failed: ${e.code} - ${e.message}');
      }
      // Keep _appCheckActivated true to prevent retry spam
      // This is expected on emulators and some devices
    } on Exception catch (e) {
      _dbg('[APP_CHECK] Activation failed: ${e.runtimeType} (non-critical)');
      // Reset flag so we can retry later
      _appCheckActivated = false;
      // Don't rethrow - App Check is non-critical for app functionality
    }
  }
  
  /// Load theme from SharedPreferences
  static Future<void> _loadTheme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isDark = prefs.getBool('darkMode') ?? false;
      themeNotifier.value = isDark ? ThemeMode.dark : ThemeMode.light;
      _dbg('Theme loaded: ${isDark ? 'dark' : 'light'}');
    } catch (e) {
      _dbg('Theme load failed: $e');
    }
  }
  
  /// Initialize OneSignal with all configuration
  static Future<void> _initializeOneSignal() async {
    if (AppConfig.oneSignalAppId.isEmpty) {
      _dbg('OneSignal skipped: ONESIGNAL_APP_ID not set');
      return;
    }
    
    _dbg('OneSignal: initializing...');
    try {
      OneSignal.initialize(AppConfig.oneSignalAppId);
      _dbg('OneSignal: initialized');
      
      // Setup notification listeners
      OneSignal.Notifications.addForegroundWillDisplayListener((event) {
        event.notification.display();
      });
      
      OneSignal.Notifications.addClickListener((event) {
        _dbg('Notification clicked');
        final data = event.notification.additionalData;
        final senderId = data?['senderId'] as String?;
        if (senderId != null) {
          navigatorKey.currentState?.push(
            MaterialPageRoute(builder: (_) => ChatScreenWrapper(receiverId: senderId)),
          );
        }
      });
      
      // Request permission (don't await - can block)
      OneSignal.Notifications.requestPermission(true);
    } catch (e) {
      _dbg('OneSignal init failed: $e');
    }
  }
}

// ── Main Entry Point ─────────────────────────────────────────────────────────

void main() async {
  // Run initialization in parallel
  await _StartupInitializer.initialize();
  
  runApp(const CryptApp());
}


// ── App ────────────────────────────────────────────────────────────────────

class CryptApp extends StatefulWidget {
  const CryptApp({super.key});

  @override
  State<CryptApp> createState() => _CryptAppState();
}

class _CryptAppState extends State<CryptApp> {
  bool _showSplash = true;

  @override
  void initState() {
    super.initState();
    
    // Wait minimum time for splash screen visibility
    // but also ensure critical initialization is complete
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _showSplash = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_showSplash) {
      return _buildSplashScreen();
    }

    return _CryptAppContent();
  }
  
  Widget _buildSplashScreen() {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3B82F6)),
      home: Scaffold(
        backgroundColor: const Color(0xFF3B82F6),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline, size: 80, color: Colors.white),
              SizedBox(height: 24),
              Text(
                'Crypt',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              SizedBox(height: 48),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CryptAppContent extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          scaffoldMessengerKey: SessionLifecycleManager.scaffoldKey,
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
            onTap: () async => SessionLifecycleManager.recordActivity(),
            onPanDown: (_) async => SessionLifecycleManager.recordActivity(),
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
  // Timer management with proper lifecycle
  Timer? _onlineTimer;
  Timer? _encryptionRetryTimer;
  Timer? _securityCheckTimer;
  
  // Flags to prevent duplicate operations
  bool _onlineTimerActive = false;
  
  /// Tracks the UID that OneSignal is currently logged in as.
  /// Prevents duplicate login calls and enables proper user switching.
  String? _currentSetupUid;

  // User data save debouncing
  DateTime? _lastSaveTime;
  Timer? _saveDebounceTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dbg('AuthWrapper initialized');

    // OneSignal subscription observer
    OneSignal.User.pushSubscription.addObserver((state) async {
      final playerId = state.current.id;
      final optedIn = state.current.optedIn;
      _dbg('OneSignal subscription changed: id=${playerId != null}, optedIn=$optedIn');
      if (playerId != null && optedIn == true) {
        await _saveUserData(playerId: playerId);
      }
    });

    // Check for existing OneSignal player ID
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final playerId = OneSignal.User.pushSubscription.id;
      if (playerId != null) {
        _saveUserData(playerId: playerId);
      }
    });
    
    // DEFER: Start periodic security checks after 5 seconds
    // This prevents frame drops during initial startup
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) _startSecurityTimer();
    });
  }
  
  void _startSecurityTimer() {
    _securityCheckTimer?.cancel();
    // Check security every 5 minutes
    _securityCheckTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _performSecurityCheck();
    });
  }
  
  Future<void> _performSecurityCheck() async {
    if (!mounted) return;
    
    final security = SecurityHardeningService();
    
    // Periodic security revalidation
    await security.periodicSecurityCheck();
    
    // Check if session needs revalidation due to low trust
    if (await security.needsSessionRevalidation()) {
      _dbg('Security check: LOW TRUST detected - session needs revalidation');
      // Could trigger re-authentication prompt here
    }
    
    _dbg('Security check: trust score = ${security.trustScore}');
  }

  /// Initializes HMAC keys for the current authenticated user
  Future<void> _initializeHmacKeys(User user) async {
    if (SecureChatService.getCurrentHmacKeyVersion() != null) {
      _dbg('HMAC keys already initialized');
      return;
    }

    try {
      final sessionId = '${user.uid}_${DateTime.now().millisecondsSinceEpoch}';
      _dbg('Initializing HMAC keys for user: ${user.uid}');
      await SecureChatService.initializeHmacKeys(
        userId: user.uid,
        sessionId: sessionId,
      );
      _dbg('HMAC keys initialized successfully');
    } catch (e) {
      _dbg('HMAC key initialization failed: $e');
    }
  }

  /// Save user data with debouncing
  Future<void> _saveUserData({String? playerId, bool? isOnline}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // Cancel any pending save
    _saveDebounceTimer?.cancel();

    // Check debounce (1 minute unless playerId is provided)
    if (playerId == null && _lastSaveTime != null) {
      final elapsed = DateTime.now().difference(_lastSaveTime!);
      if (elapsed.inSeconds < 60) return;
    }

    // Schedule save with debounce
    _saveDebounceTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        _dbg('saveUserData: writing Firestore');
        final data = <String, dynamic>{'lastSeen': FieldValue.serverTimestamp()};
        if (playerId != null) data['oneSignalPlayerId'] = playerId;
        if (isOnline != null) data['isOnline'] = isOnline;

        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .set(data, SetOptions(merge: true));
        _dbg('saveUserData: complete');

        _lastSaveTime = DateTime.now();
      } catch (e) {
        _dbg('saveUserData: failed — ${e.runtimeType}');
      }
    });
  }

  /// Setup OneSignal for authenticated user
  /// 
  /// CRITICAL: Checks if already logged in to prevent:
  /// - 409 Conflict errors from duplicate logins
  /// - Unnecessary API calls on auth rebuilds
  /// - Race conditions during rapid auth state changes
  Future<void> _setupOneSignalUser(User firebaseUser) async {
    // Skip if already set up for this UID (prevents duplicate calls in same session)
    if (_currentSetupUid == firebaseUser.uid) {
      _dbg('OneSignal login: already set up for uid=${firebaseUser.uid}, skipping');
      return;
    }

    try {
      // Check OneSignal's current external ID
      final currentExternalId = await OneSignal.User.getExternalId();
      
      // If already logged in with same ID, just update our tracking
      if (currentExternalId == firebaseUser.uid) {
        _dbg('OneSignal login: already logged in with uid=${firebaseUser.uid}, syncing state');
        _currentSetupUid = firebaseUser.uid;
        return;
      }
      
      // If logged in with different ID, logout first
      if (currentExternalId != null && currentExternalId != firebaseUser.uid) {
        _dbg('OneSignal login: switching user from $currentExternalId to ${firebaseUser.uid}');
        await OneSignal.logout();
        // Small delay to ensure logout completes
        await Future.delayed(const Duration(milliseconds: 100));
      }

      _dbg('OneSignal login: uid=${firebaseUser.uid}');
      await OneSignal.login(firebaseUser.uid);
      _currentSetupUid = firebaseUser.uid;
      _dbg('OneSignal login: success');
    } catch (e, st) {
      _dbg('OneSignal login failed: ${e.runtimeType}');
      if (kDebugMode) debugPrint('[Main] OneSignal login error: $st');
      // Don't rethrow - OneSignal errors are non-fatal
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _dbg('lifecycle: ${state.name}');
    if (state == AppLifecycleState.resumed) {
      _saveUserData(isOnline: true);
      // Also update RTDB presence via PresenceService (with error handling)
      try {
        PresenceService.setOnline();
      } catch (e) {
        _dbg('PresenceService.setOnline failed (non-fatal): $e');
      }
    } else if (state == AppLifecycleState.paused || 
               state == AppLifecycleState.inactive) {
      _saveUserData(isOnline: false);
      // Also update RTDB presence via PresenceService (with error handling)
      try {
        PresenceService.setOffline();
      } catch (e) {
        _dbg('PresenceService.setOffline failed (non-fatal): $e');
      }
    }
  }

  /// Start online status timer with guard
  void _startOnlineTimer() {
    if (_onlineTimerActive) return;
    _onlineTimerActive = true;
    
    _onlineTimer?.cancel();
    _onlineTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        _saveUserData(isOnline: true);
        _retryPendingPublicKey(currentUser);
      } else {
        _stopOnlineTimer();
      }
    });
  }

  /// Stop online timer
  void _stopOnlineTimer() {
    _onlineTimer?.cancel();
    _onlineTimer = null;
    _onlineTimerActive = false;
  }

  /// Retry pending public key upload
  Future<void> _retryPendingPublicKey(User user) async {
    try {
      final pending = await AuthService.storage.read(
        key: AuthService.publicKeyPendingKey,
      );
      if (pending == 'true') {
        await AuthService.retryPublicKeyUpload(user);
      }
    } catch (e) {
      // Ignore errors
    }
  }

  @override
  void dispose() {
    _stopOnlineTimer();
    _encryptionRetryTimer?.cancel();
    _saveDebounceTimer?.cancel();
    _securityCheckTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    OneSignal.logout();
    // Clear security caches on logout
    SecurityHardeningService().clearAllCaches();
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
          return _buildLoadingScreen('Loading...');
        }

        if (snapshot.hasData) {
          final user = snapshot.data!;
          _dbg('auth: user present, verified=${user.emailVerified}');

          // Setup OneSignal with duplicate prevention
          // _setupOneSignalUser handles internal deduplication via _currentSetupUid
          // and also checks OneSignal.User.getExternalId() to prevent 409 errors
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _setupOneSignalUser(user);
          });

          // Retry any pending public key uploads
          // This handles PERMISSION_DENIED errors from previous attempts
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            try {
              debugPrint('[KEY_UPLOAD] Checking for pending uploads after login...');
              final currentUser = FirebaseAuth.instance.currentUser;
              if (currentUser == null) {
                debugPrint('[KEY_UPLOAD] No current user, skipping retry');
                return;
              }
              final success = await EncryptionStartupService.retryPendingPublicKeyUpload(currentUser);
              if (success) {
                debugPrint('[KEY_UPLOAD] Pending upload completed or none needed');
              } else {
                debugPrint('[KEY_UPLOAD] Pending upload failed - will retry on next login');
              }
            } catch (e) {
              debugPrint('[KEY_UPLOAD] ERROR in retry callback: $e');
            }
          });

          // Not verified - show verification screen
          if (!user.emailVerified) {
            _dbg('[AUTH] showing verification screen');
unawaited(SessionLifecycleManager.terminateSession());
            _stopOnlineTimer();
            _resetAuthState();
            EncryptionStartupService.reset();
            return VerificationScreen(user: user);
          }

          // ============================================
          // NON-BLOCKING ENCRYPTION STARTUP
          // ============================================
          // CRITICAL: Navigate to app IMMEDIATELY after login.
          // Encryption setup runs in BACKGROUND.
          // No polling, no waiting, no blocking UI.
          // ============================================

          // Start encryption setup in background (non-blocking)
          // This runs PBKDF2, key restore, etc. without blocking navigation
          if (EncryptionStartupService.currentState ==
              enc.EncryptionStartupState.idle) {
            _dbg('[NAV] User authenticated - navigating to app immediately');
            _dbg('[ENC] Starting background encryption setup');

            // Start encryption in background - DO NOT await
            // Returns immediately, runs in background
            EncryptionStartupService.initialize(user: user);
          }
          
          // Initialize device trust for already-logged-in users
          // This normally happens in login() but is needed here for existing sessions
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            try {
              _dbg('[TRUST] Initializing device trust for existing session');
              await DeviceService.completeDeviceRegistration(user);
              _dbg('[TRUST] Device trust initialization complete');
            } catch (e) {
              _dbg('[TRUST] Device trust initialization failed (non-fatal): $e');
            }
          });

          // Start session monitoring (non-blocking)
          unawaited(SessionLifecycleManager.initializeSession(user));

          // Start online timer
          WidgetsBinding.instance.addPostFrameCallback((_) => _startOnlineTimer());
          
          // Initialize Realtime Database presence service
          // This provides reliable online/offline detection using onDisconnect()
          // Falls back to Firestore-only if RTDB is not configured
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            try {
              await PresenceService.initialize();
            } catch (e) {
              _dbg('PresenceService initialization failed (non-fatal): $e');
            }
          });

          // DEFER: Initialize HMAC keys after UI settles
          // Run after first frame + 1 second to prevent frame drops
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Future.delayed(const Duration(seconds: 1), () {
              _initializeHmacKeys(user);
            });
          });

          // Navigate to app shell immediately - encryption happens in background
          _dbg('[NAV] Rendering ChatListScreen');
          return const ChatListScreen();
        }

        // No user - show login
        _dbg('auth: no user');
        unawaited(SessionLifecycleManager.terminateSession());
        _stopOnlineTimer();
        _resetAuthState();
        return const LoginScreen();
      },
    );
  }

  void _resetAuthState() {
    _encryptionRetryTimer?.cancel();
    _encryptionRetryTimer = null;
    _currentSetupUid = null;
    // Reset encryption startup service on logout
    EncryptionStartupService.reset();
    // Dispose presence service on logout
    PresenceService.dispose();
  }
}

// Global instance for access
final encryptionService = EncryptionStartupService();

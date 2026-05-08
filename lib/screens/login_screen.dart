import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../main.dart';
import '../services/auth_service.dart';
import '../utils/input_validator.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool isLoading = false;
  bool showRegistration = false;

  static void _dbg(String message) {
    assert(() {
      debugPrint('[LoginScreen] $message');
      return true;
    }());
  }

  void _snack(
    String msg,
    Color color, {
    Duration? duration,
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: duration ?? const Duration(seconds: 4),
      ),
    );
  }

  /// 🔴 FIX Bug 2 — Shows key mismatch dialog when encryption keys conflict.
  /// Previously: onMismatch was never passed to AuthService.login()
  ///             Conflict was detected but user was never informed
  ///             All messages showed 🔒 with no explanation
  ///
  /// Now: Dialog blocks navigation until user makes an explicit choice.
  ///      resolveKeyMismatch() is called with their decision.
  ///      User understands the tradeoff before proceeding.
  Future<void> _handleKeyMismatch(KeyMismatchDetail detail) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !mounted) return;

    _dbg('key mismatch dialog: showing to user');

    final keepLocal = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final colors = AppColors.of(ctx);
        return AlertDialog(
          backgroundColor: colors.cardBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              const Icon(Icons.lock_reset, color: Colors.orange, size: 22),
              const SizedBox(width: 10),
              Text(
                'Encryption Key Conflict',
                style: TextStyle(
                  color: colors.primaryText,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your encryption key on this device differs from the one '
                'registered with your account. This can happen if you logged '
                'in on another device and changed your key.',
                style: TextStyle(color: colors.primaryText, fontSize: 14),
              ),
              const SizedBox(height: 16),

              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.blue.withValues(alpha: 0.25),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '📱 Use this device\'s key',
                      style: TextStyle(
                        color: Colors.blue,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'New messages will work normally. '
                      'Messages from the other device may not be readable.',
                      style: TextStyle(
                        color: colors.secondaryText,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.25),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '🔄 Keep the registered key',
                      style: TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Messages from the other device stay readable. '
                      'Delete the local key and restore from backup.',
                      style: TextStyle(
                        color: colors.secondaryText,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text(
                'Keep registered',
                style: TextStyle(color: Colors.orange),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Use this device'),
            ),
          ],
        );
      },
    );

    final resolvedKeepLocal = keepLocal ?? false;

    _dbg('key mismatch resolved: keepLocal=$resolvedKeepLocal');

    await AuthService.resolveKeyMismatch(
      user: user,
      detail: detail,
      keepLocal: resolvedKeepLocal,
      password: passwordController.text
          .trim(), // BUG 3 FIX: enables immediate restore
    );

    if (mounted) {
      _snack(
        resolvedKeepLocal
            ? '🔑 This device\'s key is now active'
            : '🔄 Registered key kept — restoring from backup on next login',
        resolvedKeepLocal ? Colors.blue : Colors.orange,
        duration: const Duration(seconds: 5),
      );
    }
  }

  Future<void> login() async {
    if (isLoading) return;

    final email = emailController.text.trim();
    final pass = passwordController.text.trim();

    final emailErr = InputValidator.validateEmail(email);
    if (emailErr != null) {
      _snack(emailErr, Colors.red);
      return;
    }
    if (pass.isEmpty) {
      _snack("Password cannot be empty", Colors.red);
      return;
    }

    setState(() => isLoading = true);

    try {
      await AuthService.login(
        email,
        pass,
        onMismatch: _handleKeyMismatch,
      );

      if (!mounted) return;

      _dbg('login: successful');
    } on FirebaseAuthException catch (e) {
      _dbg('login: FirebaseAuthException code=${e.code}');

      if (!mounted) return;

      final message = _mapFirebaseLoginError(e.code);
      _snack(message, Colors.red);
    } catch (e) {
      _dbg('login: unexpected error — ${e.runtimeType}');
      if (!mounted) return;
      _snack("Something went wrong. Please try again.", Colors.red);
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> register() async {
    if (isLoading) return;

    final email = emailController.text.trim();
    final pass = passwordController.text.trim();

    final emailErr = InputValidator.validateEmail(email);
    if (emailErr != null) {
      _snack(emailErr, Colors.red);
      return;
    }
    if (pass.length < 6) {
      _snack("Password must be at least 6 characters", Colors.red);
      return;
    }

    setState(() => isLoading = true);

    try {
      await AuthService.register(email, pass);

      if (!mounted) return;

      _dbg('register: account created successfully');

      _snack(
        "✅ Account created! Check your email for a verification link.",
        Colors.green,
        duration: const Duration(seconds: 6),
      );

      setState(() => showRegistration = false);
      emailController.clear();
      passwordController.clear();
    } on FirebaseAuthException catch (e) {
      _dbg('register: FirebaseAuthException code=${e.code}');
      if (!mounted) return;
      final msg = _mapFirebaseRegisterError(e.code);
      _snack(msg, Colors.red);
    } catch (e) {
      _dbg('register: unexpected error — ${e.runtimeType}');
      if (!mounted) return;
      _snack("Something went wrong. Please try again.", Colors.red);
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  String _mapFirebaseLoginError(String code) {
    return switch (code) {
      'user-not-found' => '❌ No account found with that email',
      'wrong-password' => '❌ Incorrect password',
      'invalid-email' => '❌ Invalid email address',
      'too-many-requests' => '⏳ Too many attempts. Please try again later.',
      'user-disabled' => '❌ This account has been disabled',
      'invalid-credential' => '❌ Incorrect email or password',
      _ => '❌ Login failed. Please try again.',
    };
  }

  String _mapFirebaseRegisterError(String code) {
    return switch (code) {
      'email-already-in-use' => '❌ An account already exists with that email',
      'weak-password' => '❌ Password too weak (minimum 6 characters)',
      'invalid-email' => '❌ Invalid email format',
      'operation-not-allowed' => '❌ Registration is currently disabled',
      _ => '❌ Registration failed. Please try again.',
    };
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return Scaffold(
      backgroundColor: colors.screenBg,
      appBar: AppBar(
        backgroundColor: colors.appBarBg,
        elevation: 0,
        title: Text(
          showRegistration ? "Create Account 🔐" : "Welcome 🔐",
          style: TextStyle(
            color: colors.primaryText,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: colors.accent.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.lock_outline,
                    size: 60,
                    color: colors.accent,
                  ),
                ),
              ),
              const SizedBox(height: 40),

              TextField(
                controller: emailController,
                enabled: !isLoading,
                style: TextStyle(color: colors.primaryText),
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: "Email",
                  labelStyle: TextStyle(color: colors.secondaryText),
                  prefixIcon: Icon(
                    Icons.email_outlined,
                    color: colors.secondaryText,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colors.borderColor),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colors.accent, width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              TextField(
                controller: passwordController,
                enabled: !isLoading,
                style: TextStyle(color: colors.primaryText),
                obscureText: true,
                decoration: InputDecoration(
                  labelText: "Password",
                  labelStyle: TextStyle(color: colors.secondaryText),
                  prefixIcon: Icon(
                    Icons.lock_outline,
                    color: colors.secondaryText,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colors.borderColor),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colors.accent, width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 40),

              ElevatedButton(
                onPressed: isLoading
                    ? null
                    : (showRegistration ? register : login),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 2,
                  shadowColor: colors.accent.withValues(alpha: 0.4),
                ),
                child: isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        showRegistration ? "Create Account" : "Login",
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
              const SizedBox(height: 16),

              OutlinedButton(
                onPressed: isLoading
                    ? null
                    : () => setState(() {
                        showRegistration = !showRegistration;
                        passwordController.clear();
                      }),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.accent,
                  side: BorderSide(color: colors.accent, width: 1.5),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  showRegistration
                      ? "Already have an account? Login"
                      : "Don't have an account? Sign up",
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              if (!showRegistration)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.blue.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        color: Colors.blue,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          "New user? Create an account to get started.",
                          style: TextStyle(
                            color: Colors.blue.shade700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

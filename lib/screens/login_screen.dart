import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../main.dart';
import '../services/auth_service.dart';

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
                      'Use this device\'s key',
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
                      'Keep the registered key',
                      style: TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'This device\'s messages may not be readable. '
                      'Requires re-login on other device to sync.',
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
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(
                foregroundColor: Colors.blue,
              ),
              child: const Text('Use This Device'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: TextButton.styleFrom(
                foregroundColor: Colors.orange,
              ),
              child: const Text('Keep Registered'),
            ),
          ],
        );
      },
    );

    if (keepLocal == null) return;

    _dbg('key mismatch dialog: user chose ${keepLocal ? 'local' : 'remote'}');

    await AuthService.resolveKeyMismatch(
      user: user,
      detail: detail,
      keepLocal: keepLocal,
    );
  }

  Future<void> login() async {
    if (isLoading) return;

    final email = emailController.text.trim();
    final password = passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      _snack('Please enter both email and password', Colors.orange);
      return;
    }

    setState(() => isLoading = true);

    try {
      final user = await AuthService.login(email, password);

      if (!mounted) return;

      if (user == null) {
        _snack('Login failed', Colors.red);
        setState(() => isLoading = false);
        return;
      }

      if (!user.emailVerified) {
        _snack(
          'Please verify your email first. Check your inbox.',
          Colors.orange,
          duration: const Duration(seconds: 5),
        );
        setState(() => isLoading = false);
        return;
      }

      _snack('Welcome back!', Colors.green);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      _snack(_mapFirebaseLoginError(e.code), Colors.red);
      setState(() => isLoading = false);
    } catch (e) {
      if (!mounted) return;
      _snack('Login failed: ${e.runtimeType}', Colors.red);
      setState(() => isLoading = false);
    }
  }

  Future<void> register() async {
    if (isLoading) return;

    final email = emailController.text.trim();
    final password = passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      _snack('Please enter both email and password', Colors.orange);
      return;
    }

    if (password.length < 6) {
      _snack('Password must be at least 6 characters', Colors.orange);
      return;
    }

    setState(() => isLoading = true);

    try {
      final user = await AuthService.register(email, password);

      if (!mounted) return;

      if (user != null) {
        _snack(
          'Account created! Please check your email to verify.',
          Colors.green,
          duration: const Duration(seconds: 5),
        );
        setState(() {
          showRegistration = false;
          isLoading = false;
        });
      } else {
        _snack('Registration failed', Colors.red);
        setState(() => isLoading = false);
      }
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      _snack(_mapFirebaseRegisterError(e.code), Colors.red);
      setState(() => isLoading = false);
    } catch (e) {
      if (!mounted) return;
      _snack('Registration failed', Colors.red);
      setState(() => isLoading = false);
    }
  }

  String _mapFirebaseLoginError(String code) {
    return switch (code) {
      'user-not-found' => 'No account found with that email',
      'wrong-password' => 'Incorrect password',
      'invalid-email' => 'Invalid email address',
      'too-many-requests' => 'Too many attempts. Please try again later.',
      'user-disabled' => 'This account has been disabled',
      'invalid-credential' => 'Incorrect email or password',
      _ => 'Login failed. Please try again.',
    };
  }

  String _mapFirebaseRegisterError(String code) {
    return switch (code) {
      'email-already-in-use' => 'An account already exists with that email',
      'weak-password' => 'Password too weak (minimum 6 characters)',
      'invalid-email' => 'Invalid email format',
      'operation-not-allowed' => 'Registration is currently disabled',
      _ => 'Registration failed. Please try again.',
    };
  }

  /// Shows the forgot password dialog with email input.
  void _showForgotPasswordDialog() {
    _dbg('[AUTH] Showing forgot password dialog');
    showDialog(
      context: context,
      builder: (context) => const ForgotPasswordDialog(),
    );
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
          showRegistration ? 'Create Account' : 'Welcome',
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
                  labelText: 'Email',
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
                  labelText: 'Password',
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
              const SizedBox(height: 8),

              // Forgot Password Button
              if (!showRegistration)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: isLoading ? null : _showForgotPasswordDialog,
                    icon: const Icon(Icons.lock_reset, size: 16),
                    label: const Text(
                      'Forgot Password?',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: colors.accent,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      minimumSize: const Size(120, 36),
                    ),
                  ),
                ),
              const SizedBox(height: 32),

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
                        showRegistration ? 'Create Account' : 'Login',
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
                      ? 'Already have an account? Login'
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
                          'New user? Create an account to get started.',
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

/// Forgot Password Dialog
/// Secure password reset flow with 30-second cooldown timer.
class ForgotPasswordDialog extends StatefulWidget {
  const ForgotPasswordDialog({super.key});

  @override
  State<ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<ForgotPasswordDialog> {
  final emailController = TextEditingController();

  bool isLoading = false;
  bool emailSent = false;
  int cooldownSeconds = 0;
  Timer? cooldownTimer;
  String? errorMessage;

  static void _dbg(String message) {
    assert(() {
      debugPrint('[RESET] $message');
      return true;
    }());
  }

  @override
  void dispose() {
    emailController.dispose();
    cooldownTimer?.cancel();
    super.dispose();
  }

  void _startCooldown() {
    cooldownSeconds = 30;
    cooldownTimer?.cancel();
    cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        cooldownSeconds--;
        if (cooldownSeconds <= 0) {
          timer.cancel();
        }
      });
    });
  }

  Future<void> _sendResetEmail() async {
    if (isLoading) return;

    final email = emailController.text.trim();
    _dbg('[EMAIL] Attempting reset for: $email');

    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final result = await AuthService.sendPasswordResetEmail(email);

      if (!mounted) return;

      if (result.success) {
        _dbg('[EMAIL] Reset email sent successfully');
        setState(() {
          emailSent = true;
          isLoading = false;
        });
        _startCooldown();
      } else {
        _dbg('[EMAIL] Failed: ${result.message}');
        setState(() {
          errorMessage = result.message;
          isLoading = false;
        });
      }
    } catch (e) {
      _dbg('[EMAIL] Unexpected error: $e');
      if (!mounted) return;
      setState(() {
        errorMessage = 'An unexpected error occurred. Please try again.';
        isLoading = false;
      });
    }
  }

  void _close() {
    _dbg('[AUTH] Closing forgot password dialog');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return Dialog(
      backgroundColor: colors.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colors.accent.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      emailSent ? Icons.check_circle_outline : Icons.lock_reset,
                      color: colors.accent,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      emailSent ? 'Check Your Email' : 'Reset Password',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: colors.primaryText,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _close,
                    icon: Icon(Icons.close, color: colors.secondaryText),
                    splashRadius: 20,
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Content
              if (emailSent) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.green.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.mark_email_read_outlined,
                        color: Colors.green,
                        size: 40,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'If an account exists for this email, a reset link has been sent.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: colors.primaryText,
                          fontSize: 14,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Check your inbox and spam folder.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: colors.secondaryText,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                Text(
                  'Enter your email address and we will send you a link to reset your password.',
                  style: TextStyle(
                    color: colors.secondaryText,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),

                TextField(
                  controller: emailController,
                  enabled: !isLoading,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  style: TextStyle(color: colors.primaryText),
                  decoration: InputDecoration(
                    labelText: 'Email',
                    labelStyle: TextStyle(color: colors.secondaryText),
                    hintText: 'your@email.com',
                    hintStyle: TextStyle(
                      color: colors.secondaryText.withValues(alpha: 0.5),
                    ),
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
                    errorText: errorMessage,
                    errorStyle: const TextStyle(color: Colors.red),
                  ),
                ),
              ],
              const SizedBox(height: 24),

              // Action Button
              if (emailSent) ...[
                ElevatedButton.icon(
                  onPressed: cooldownSeconds > 0 ? null : _sendResetEmail,
                  icon: cooldownSeconds > 0
                      ? const SizedBox.shrink()
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(
                    cooldownSeconds > 0
                        ? 'Resend in ${cooldownSeconds}s'
                        : 'Resend Email',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _close,
                  child: Text(
                    'Back to Login',
                    style: TextStyle(color: colors.accent),
                  ),
                ),
              ] else ...[
                ElevatedButton(
                  onPressed: isLoading ? null : _sendResetEmail,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
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
                      : const Text(
                          'Send Reset Link',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _close,
                  child: Text(
                    'Cancel',
                    style: TextStyle(color: colors.secondaryText),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

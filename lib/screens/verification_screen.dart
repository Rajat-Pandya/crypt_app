import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../main.dart';
import '../services/auth_service.dart';

class VerificationScreen extends StatefulWidget {
  final User user;

  const VerificationScreen({super.key, required this.user});

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  bool isChecking = false;
  bool isResending = false;
  bool isVerified = false;
  Timer? _checkTimer;

  // ── Internal debug helper ──────────────────────────────────────────────
  static void _dbg(String message) {
    assert(() {
      debugPrint('[VerificationScreen] $message');
      return true;
    }());
  }

  // ────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _dbg('initState: starting verification poll');

    // Auto-check verification every 3 seconds.
    // isChecking guard inside _checkEmailVerification prevents
    // overlapping calls if a check takes longer than the interval.
    _checkTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _checkEmailVerification(),
    );
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    _dbg('dispose: timer cancelled');
    super.dispose();
  }

  // ── Email Verification Check ───────────────────────────────────────────

  Future<void> _checkEmailVerification() async {
    // ── isChecking guard ────────────────────────────────────────────────
    // Flutter is single-threaded so this read-then-write is safe.
    // The guard prevents a slow network call from overlapping with
    // the next timer tick.
    if (isChecking || isVerified) return;

    setState(() => isChecking = true);

    try {
      await FirebaseAuth.instance.currentUser?.reload();
      final currentUser = FirebaseAuth.instance.currentUser;
      final verified = currentUser?.emailVerified ?? false;

      // ✅ Log verification result as bool — not the email address
      _dbg('verification check: emailVerified=$verified');

      if (verified && mounted && !isVerified) {
        // ── Cancel timer immediately ─────────────────────────────────
        // Must happen before the await below so no further checks
        // fire during the snackbar delay.
        _checkTimer?.cancel();
        _checkTimer = null;

        setState(() => isVerified = true);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('✅ Email verified successfully!'),
              backgroundColor: Colors.green,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }

        // Brief delay so user sees the success state before redirect.
        await Future.delayed(const Duration(milliseconds: 1500));

        // ── Sign out to trigger AuthWrapper rebuild ──────────────────
        // VerificationScreen is shown by AuthWrapper as the home widget
        // — it is not on the navigation stack.
        // Signing out fires authStateChanges() → AuthWrapper rebuilds
        // → shows LoginScreen automatically.
        // No Navigator call is needed or correct here.
        if (mounted) {
          await FirebaseAuth.instance.signOut();
        }
      }
    } catch (e) {
      // ✅ Log type only — Firebase reload errors can contain email
      _dbg('verification check failed — ${e.runtimeType}');
    } finally {
      if (mounted) setState(() => isChecking = false);
    }
  }

  // ── Resend Email ───────────────────────────────────────────────────────

  Future<void> _resendEmail() async {
    if (isResending) return;
    setState(() => isResending = true);

    try {
      await AuthService.resendVerificationEmail();
      if (!mounted) return;
      _showSnack('✅ Verification email sent! Check your inbox', Colors.green);
    } catch (e) {
      // ✅ Show generic error — not e.toString()
      _dbg('resend failed — ${e.runtimeType}');
      if (!mounted) return;
      _showSnack('❌ Failed to resend. Please try again.', Colors.red);
    } finally {
      if (mounted) setState(() => isResending = false);
    }
  }

  // ── Logout ─────────────────────────────────────────────────────────────

  Future<void> _logout() async {
    // Cancel our own poll timer before signing out.
    // AuthService.logout() handles the rest.
    _checkTimer?.cancel();
    _checkTimer = null;
    _dbg('user triggered logout from verification screen');
    await AuthService.logout(context);
    // AuthWrapper reacts to authStateChanges() — no Navigator call needed.
  }

  // ── Snack helper ───────────────────────────────────────────────────────

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    // ── Fix: WillPopScope → PopScope ──────────────────────────────────
    // WillPopScope is deprecated in Flutter 3.12+.
    // PopScope with canPop: false prevents back navigation entirely
    // while unverified — the logout button is the only exit path.
    // When verified, canPop: true allows the back gesture to work
    // (though AuthWrapper redirects automatically via signOut).
    return PopScope(
      canPop: isVerified,
      // ✅ No onPopInvokedWithResult needed — we just block the pop
      //    when unverified. No state change required on pop attempt.
      child: Scaffold(
        backgroundColor: colors.screenBg,
        appBar: AppBar(
          backgroundColor: colors.appBarBg,
          elevation: 0,
          // ── Fix: AppBar title now uses theme color ─────────────────
          // Previously: const TextStyle(fontWeight: FontWeight.w600)
          // Missing color caused wrong title color in dark/custom themes
          title: Text(
            isVerified ? 'Email Verified! 🎉' : 'Verify Your Email 📧',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: colors.primaryText, // ✅ themed
            ),
          ),
          centerTitle: true,
          // ── Back button ─────────────────────────────────────────────
          // Hidden when verified — PopScope and signOut() handle exit.
          // Shown when unverified so user can reach the logout button
          // via the AppBar action, not back navigation.
          // Back is blocked by PopScope(canPop: false) when unverified
          // so automaticallyImplyLeading only affects visual presence.
          automaticallyImplyLeading: false,
          // ✅ Always hidden — back is either blocked (unverified)
          //    or irrelevant (verified, signOut handles navigation)
          //    Logout button in actions is the explicit exit
          actions: isVerified
              ? null
              : [
                  IconButton(
                    icon: Icon(Icons.logout, color: colors.primaryText),
                    onPressed: _logout,
                    tooltip: 'Logout',
                  ),
                ],
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // ── Status icon ──────────────────────────────────────
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: isVerified
                        ? Colors.green.withValues(alpha: 0.1)
                        : Colors.blue.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isVerified
                        ? Icons.check_circle_outline
                        : Icons.mail_outline,
                    size: 70,
                    color: isVerified ? Colors.green : Colors.blue,
                  ),
                ),
                const SizedBox(height: 32),

                // ── Title ─────────────────────────────────────────────
                Text(
                  isVerified ? 'Email Verified!' : 'Check Your Email',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: isVerified ? Colors.green : colors.primaryText,
                  ),
                ),
                const SizedBox(height: 12),

                // ── Email display ─────────────────────────────────────
                // Showing the registered email is intentional UX —
                // confirms to the user which inbox to check.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: isVerified
                        ? Colors.green.withValues(alpha: 0.1)
                        : Colors.blue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isVerified
                          ? Colors.green.withValues(alpha: 0.3)
                          : Colors.blue.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    widget.user.email ?? 'your email',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: isVerified ? Colors.green : Colors.blue,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 24),

                // ── Status body ───────────────────────────────────────
                if (isVerified)
                  _buildVerifiedBody(colors)
                else
                  _buildWaitingBody(colors),

                // ── Action buttons (unverified only) ──────────────────
                if (!isVerified) ...[
                  const SizedBox(height: 32),
                  _buildTroubleshootingTile(colors),
                  const SizedBox(height: 32),
                  _buildResendButton(colors),
                  const SizedBox(height: 12),
                  _buildCheckNowButton(colors),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Body sub-widgets ───────────────────────────────────────────────────

  Widget _buildVerifiedBody(AppColors colors) {
    return Column(
      children: [
        Text(
          '🎉 Your email has been verified successfully!',
          style: TextStyle(
            fontSize: 16,
            color: Colors.green.shade700,
            fontWeight: FontWeight.w600,
            height: 1.6,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          'Redirecting to login...',
          style: TextStyle(
            fontSize: 14,
            color: colors.secondaryText,
            fontStyle: FontStyle.italic,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        const SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(color: Colors.green, strokeWidth: 3),
        ),
      ],
    );
  }

  Widget _buildWaitingBody(AppColors colors) {
    return Column(
      children: [
        Text(
          'We sent a verification link to your email.\n\n'
          'Click the link to verify your account and get access to the app.',
          style: TextStyle(
            fontSize: 16,
            color: colors.secondaryText,
            height: 1.6,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),

        // ── Poll status indicator ──────────────────────────────────
        if (isChecking)
          Column(
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(color: colors.accent),
              ),
              const SizedBox(height: 12),
              Text(
                'Checking verification...',
                style: TextStyle(fontSize: 14, color: colors.secondaryText),
              ),
            ],
          )
        else
          Column(
            children: [
              Text(
                '⏳ Waiting for verification...',
                style: TextStyle(
                  fontSize: 14,
                  color: colors.secondaryText,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Auto-checking every 3 seconds',
                style: TextStyle(
                  fontSize: 12,
                  color: colors.secondaryText,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildTroubleshootingTile(AppColors colors) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.lightbulb_outline,
                color: Colors.orange,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'Troubleshooting',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Colors.orange.shade700,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            "💡 Didn't receive the email?\n"
            '• Check your spam/junk folder\n'
            '• Tap "Resend Email" below\n'
            '• Wait a few moments',
            style: TextStyle(
              fontSize: 13,
              color: Colors.orange.shade700,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResendButton(AppColors colors) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: isResending ? null : _resendEmail,
        icon: isResending
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.mail_outline),
        label: Text(isResending ? 'Sending...' : 'Resend Email'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.orange,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  Widget _buildCheckNowButton(AppColors colors) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: isChecking ? null : _checkEmailVerification,
        icon: isChecking
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.refresh),
        label: const Text('Check Now'),
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.accent,
          side: BorderSide(color: colors.accent),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

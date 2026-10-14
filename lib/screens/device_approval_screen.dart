import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/device_trust_service.dart';
import '../services/device_encryption_service.dart';
import '../services/encryption_startup_service.dart';
import '../services/key_backup_service.dart';
import 'chat_list_screen.dart';

/// Screen for handling device trust approval.
///
/// Shows when a user logs in on a new device that needs approval.
/// Supports two approval methods:
/// 1. OTP - Enter a code from an existing device
/// 2. Existing device approval - Wait for approval from another device
class DeviceApprovalScreen extends StatefulWidget {
  const DeviceApprovalScreen({super.key});

  @override
  State<DeviceApprovalScreen> createState() => _DeviceApprovalScreenState();
}

class _DeviceApprovalScreenState extends State<DeviceApprovalScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _otpController = TextEditingController();

  DeviceTrustState? _trustState;
  bool _isLoading = true;
  String? _errorMessage;
  String? _successMessage;
  final List<Map<String, dynamic>> _pendingDevices = [];

  StreamSubscription<DeviceTrustState>? _trustSubscription;

  void _dbg(String message) {
    assert(() {
      debugPrint('[DEVICE_APPROVAL] $message');
      return true;
    }());
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initialize();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _otpController.dispose();
    _trustSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showError('No user logged in');
      return;
    }

    // Listen to trust state changes
    _trustSubscription = DeviceTrustService.listenToTrustChanges(user).listen(
      (state) async {
        if (!mounted) return;
        
        setState(() {
          _trustState = state;
        });
        
        if (state.isTrusted) {
          // Device is now trusted - we need to restore keys from backup
          // This happens when approved from another device (not via OTP)
          _dbg('Device approved via another device - restoring keys');
          try {
            await _restoreKeysAfterApproval(user);
          } catch (e) {
            _dbg('Error restoring keys after approval: $e');
            _showError('Failed to restore keys: $e');
            // Still try to initialize encryption with new keys
            if (mounted) _onDeviceApproved();
          }
        }
      },
      onError: (e) {
        _dbg('Trust listener error: $e');
        _showError('Trust state error: $e');
      },
    );

    // Get current trust state
    final state = await DeviceTrustService.getTrustState(user);
    setState(() {
      _trustState = state;
      _isLoading = false;
    });

    // If already trusted, restore keys and complete
    if (state.isTrusted) {
      _dbg('Device already trusted - restoring encryption keys');
      await _restoreKeysAfterApproval(user);
      return;
    }
  }

  void _onDeviceApproved() {
    setState(() {
      _successMessage = 'Device approved! Initializing encryption...';
    });

    // Initialize encryption after approval
    _initializeEncryption();
  }

  Future<void> _initializeEncryption() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      // Initialize device encryption keys
      await DeviceEncryptionService.initializeAfterApproval(user);

      // Start encryption startup service
      await EncryptionStartupService.initialize(user: user);

      if (mounted) {
        // Navigate to chat list using MaterialPageRoute
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ChatListScreen()),
        );
      }
    } catch (e) {
      _showError('Failed to initialize encryption: $e');
    }
  }

  Future<void> _submitOTP() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final otp = _otpController.text.trim();
    if (otp.length != 6) {
      _showError('Please enter a valid 6-digit code');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final success = await DeviceTrustService.validateOTP(
        user: user,
        otp: otp,
      );

      if (success) {
        setState(() {
          _successMessage =
              'Device approved via OTP! Restoring encryption keys...';
          _errorMessage = null;
        });

        // CRITICAL: After OTP approval, we need to restore keys from backup
        // Device B needs the SAME keys as Device A to decrypt messages
        await _restoreKeysAfterApproval(user);
      } else {
        _showError('Invalid or expired code');
      }
    } catch (e) {
      _showError('Failed to validate code: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Restore encryption keys from backup after device approval.
  /// This is CRITICAL for multi-device sync - Device B needs the same keys as Device A.
  Future<void> _restoreKeysAfterApproval(User user) async {
    _dbg('Restoring keys after approval - prompting for password');

    // Show password dialog to decrypt key backup
    final password = await _showPasswordDialog();
    if (password == null || password.isEmpty) {
      _showError('Password required to restore encryption keys');
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Try to restore keys from backup
      final result = await KeyBackupService.restorePrivateKey(
        user: user,
        password: password,
      );

      switch (result) {
        case KeyRestoreResult.success:
          _dbg('Keys restored successfully from backup');
          setState(() {
            _successMessage = 'Encryption keys restored! Opening chats...';
          });
          _onDeviceApproved();
          break;

        case KeyRestoreResult.noBackup:
          _dbg('No backup found - this is a new account, generating new keys');
          // For new accounts with no backup, proceed with key generation
          setState(() {
            _successMessage = 'Setting up encryption on this device...';
          });
          _onDeviceApproved();
          break;

        case KeyRestoreResult.wrongPassword:
          _showError('Wrong password. Cannot restore encryption keys.');
          // Still allow proceeding - user might have no messages yet
          _showNoKeyBackupWarning();
          // Dialog's Continue button will call _onDeviceApproved()
          break;
      }
    } catch (e) {
      _dbg('Failed to restore keys: $e');
      _showError('Failed to restore encryption keys: $e');
      // Still allow proceeding - will generate new keys
      _showNoKeyBackupWarning();
      // Dialog's Continue button will call _onDeviceApproved()
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Show password dialog to decrypt key backup
  Future<String?> _showPasswordDialog() async {
    final passwordController = TextEditingController();

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Enter Account Password',
          style: TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'To restore your encrypted messages on this device, please enter your account password.',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              obscureText: true,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Your account password',
                hintStyle: const TextStyle(color: Colors.white30),
                filled: true,
                fillColor: Colors.white.withOpacity(0.1),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white60),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(passwordController.text),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }

  /// Show warning when no key backup exists
  void _showNoKeyBackupWarning() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.orange),
            SizedBox(width: 8),
            Text('No Key Backup', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: const Text(
          'Could not restore encryption keys. You may not be able to read previous messages.\n\n'
          'New messages will work normally.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _onDeviceApproved();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  void _showError(String message) {
    setState(() {
      _errorMessage = message;
      _successMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 40),
                // Header
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.security,
                        color: Colors.orange,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 16),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'New Device',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'This device needs to be approved',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 40),

                // Device info
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Device Information',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildInfoRow(
                        'Device ID',
                        _trustState?.deviceId ?? 'Loading...',
                      ),
                      const SizedBox(height: 8),
                      _buildInfoRow(
                        'Status',
                        _trustState?.status.name ?? 'Unknown',
                        valueColor: _getStatusColor(_trustState?.status),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 32),

                // Tab bar
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: TabBar(
                    controller: _tabController,
                    indicator: BoxDecoration(
                      color: Colors.orange.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    labelColor: Colors.orange,
                    unselectedLabelColor: Colors.white60,
                    tabs: const [
                      Tab(text: 'Enter Code'),
                      Tab(text: 'Wait for Approval'),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // Tab content
                SizedBox(
                  height: 300,
                  child: TabBarView(
                    controller: _tabController,
                    children: [_buildOTPTab(), _buildWaitTab()],
                  ),
                ),

                // Messages
                if (_errorMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: Colors.red,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                if (_successMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle,
                          color: Colors.green,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _successMessage!,
                            style: const TextStyle(
                              color: Colors.green,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                if (_isLoading)
                  const Center(
                    child: CircularProgressIndicator(color: Colors.orange),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {Color? valueColor}) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 13),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: valueColor ?? Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Color? _getStatusColor(DeviceTrustStatus? status) {
    switch (status) {
      case DeviceTrustStatus.trusted:
        return Colors.green;
      case DeviceTrustStatus.pending:
      case DeviceTrustStatus.awaitingApproval:
        return Colors.orange;
      case DeviceTrustStatus.rejected:
      case DeviceTrustStatus.revoked:
      case DeviceTrustStatus.failed:
        return Colors.red;
      default:
        return Colors.white60;
    }
  }

  Widget _buildOTPTab() {
    return SingleChildScrollView(
      child: Column(
        children: [
          const Icon(Icons.pin, color: Colors.orange, size: 48),
          const SizedBox(height: 16),
          const Text(
            'Enter 6-digit code',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Get the code from your existing device\n(Settings → Linked Devices → Add Device)',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, fontSize: 14),
          ),
          const SizedBox(height: 32),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withAlpha(51)),
            ),
            child: TextField(
              controller: _otpController,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 6,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(20),
                hintText: '000000',
                hintStyle: TextStyle(color: Colors.white30),
                counterText: '',
              ),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _submitOTP,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text(
                      'Verify Code',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaitTab() {
    return SingleChildScrollView(
      child: Column(
        children: [
          const Icon(Icons.devices, color: Colors.orange, size: 48),
          const SizedBox(height: 16),
          const Text(
            'Approve from another device',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Open the app on one of your trusted devices\nand approve this device.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, fontSize: 14),
          ),
          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withOpacity(0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.orange, size: 20),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'This screen will automatically update when approved.',
                    style: TextStyle(color: Colors.orange, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Waiting indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    color: Colors.orange,
                    strokeWidth: 2,
                  ),
                ),
                SizedBox(width: 12),
                Text(
                  'Waiting for approval...',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

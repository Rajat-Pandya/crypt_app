import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../main.dart';
import '../widgets/security_indicators.dart';
import '../widgets/security_details_sheet.dart';
import '../services/auth_service.dart';
import '../services/device_trust_state_manager.dart';
import 'linked_devices_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  static Future<bool> isSoundEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('sound') ?? true;
  }

  static Future<void> vibrateIfEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('vibration') ?? true;
    if (!enabled) return;
    HapticFeedback.mediumImpact();
  }

  static Future<bool> isMessagePreviewEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('messagePreview') ?? true;
  }

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isDarkMode = false;
  bool _notificationsEnabled = true;
  bool _messagePreview = true;
  bool _soundEnabled = true;
  bool _vibrationEnabled = true;
  bool _isLoading = true;
  
  // Security status
  SecurityStatusData _securityStatus = const SecurityStatusData(
    trustScore: 100,
    isHmacVerified: true,
    isSecureSendingEnabled: true,
  );
  String? _keyFingerprint;
  bool _isLoadingSecurity = true;
  bool _hasPendingKeyUpload = false;
  Timer? _refreshTimer;
  int _refreshAttempts = 0;
  static const int _maxRefreshAttempts = 10;
  
  // Stream subscription for encryption session state changes
  late final _sessionStateSubscription = DeviceTrustStateManager.stateStream.listen(
    (state) {
      debugPrint('[Settings] Session state changed: keyUploaded=${state.isKeyUploaded}, deviceTrusted=${state.isDeviceTrusted}, encryptionActive=${state.isEncryptionActive}');
      // Refresh security status when session state changes
      // Add a small delay to ensure state propagation is complete
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          _loadSecurityStatus();
        }
      });
    },
    onError: (e) {
      debugPrint('[Settings] Session state stream error: $e');
    },
  );

  @override
  void initState() {
    super.initState();
    debugPrint('[Settings] initState: START');
    _loadSettings();
    _loadSecurityStatus();
    
    // Start periodic refresh until encryption is fully active
    _startPeriodicRefresh();
  }
  
  void _startPeriodicRefresh() {
    _refreshTimer?.cancel();
    _refreshAttempts = 0;
    
    // Check every 500ms for up to 10 attempts (5 seconds total)
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      _refreshAttempts++;
      
      final sessionState = DeviceTrustStateManager.currentState;
      debugPrint('[Settings] Periodic refresh #$_refreshAttempts: encryptionActive=${sessionState.isEncryptionActive}');
      
      // Refresh the UI
      if (mounted) {
        _loadSecurityStatus();
      }
      
      // Stop refreshing if encryption is active or we've tried too many times
      if (sessionState.isEncryptionActive || _refreshAttempts >= _maxRefreshAttempts) {
        debugPrint('[Settings] Stopping periodic refresh: encryptionActive=${sessionState.isEncryptionActive}, attempts=$_refreshAttempts');
        timer.cancel();
      }
    });
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Refresh security status when screen becomes visible
    debugPrint('[Settings] didChangeDependencies: refreshing security status');
    _loadSecurityStatus();
  }
  
  @override
  void dispose() {
    _refreshTimer?.cancel();
    _sessionStateSubscription.cancel();
    super.dispose();
  }
  
  Future<void> _loadSecurityStatus() async {
    debugPrint('[SECURITY_UI] _loadSecurityStatus: START');
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        setState(() => _isLoadingSecurity = false);
        return;
      }
      
      // Read current state from session manager FRESH each time
      // Don't cache it - read it fresh for each check
      
      // Load local keys first
      final privateKey = await AuthService.storage.read(key: 'private_key');
      
      // Calculate trust score with PROPER STATE SEPARATION
      int trustScore = 100;
      final issues = <SecurityIssue>[];
      
      // Rule 1: Show "Private Key Missing" ONLY if no local key
      if (privateKey == null) {
        trustScore -= 40;
        issues.add(const SecurityIssue(
          title: 'Private Key Missing',
          description: 'Your private key is not available. Please re-login.',
          severity: SecurityTrustLevel.critical,
        ));
        debugPrint('[TRUST] Private key missing, score -40');
      }
      
      // Rule 2: Show "Public Key Missing" ONLY if key not uploaded to Firestore
      // Read FRESH state here
      if (!DeviceTrustStateManager.currentState.isKeyUploaded) {
        trustScore -= 30;
        
        // Check if upload is pending or failed
        final hasLocalKeys = privateKey != null;
        final pendingUpload = await AuthService.storage.read(key: 'public_key_upload_pending');
        
        if (hasLocalKeys && pendingUpload == 'true') {
          // Keys exist locally but upload is pending
          issues.add(SecurityIssue(
            title: 'Public Key Upload Pending',
            description: 'Your public key is waiting to upload. Pull down to refresh or tap "Retry Upload" below.',
            severity: SecurityTrustLevel.warning,
          ));
          _hasPendingKeyUpload = true;
        } else if (hasLocalKeys) {
          // Keys exist locally but not marked for upload - may be uploading now
          issues.add(SecurityIssue(
            title: 'Public Key Uploading',
            description: 'Your public key is being uploaded. Please wait a moment and refresh.',
            severity: SecurityTrustLevel.warning,
          ));
          _hasPendingKeyUpload = true;
        } else {
          // No local keys at all
          issues.add(const SecurityIssue(
            title: 'Public Key Missing',
            description: 'Your public key has not been generated. Please re-login.',
            severity: SecurityTrustLevel.critical,
          ));
        }
        debugPrint('[TRUST] Public key not uploaded, score -30, pending=$pendingUpload');
      }
      
      // Rule 3: Show "Device Approval Pending" if pending approval
      // Read FRESH state here
      if (DeviceTrustStateManager.currentState.isDevicePendingApproval) {
        trustScore -= 10;
        issues.add(const SecurityIssue(
          title: 'Device Approval Pending',
          description: 'This device is pending approval. Some features may be limited.',
          severity: SecurityTrustLevel.warning,
        ));
        debugPrint('[TRUST] Device pending approval, score -10');
      }
      
      // Rule 4: Show "Encryption Not Active" if key uploaded but not trusted
      // Read FRESH state here - this is critical!
      final isKeyUploaded = DeviceTrustStateManager.currentState.isKeyUploaded;
      final isEncryptionActive = DeviceTrustStateManager.currentState.isEncryptionActive;
      
      debugPrint('[STATUS_CHECK] isKeyUploaded: $isKeyUploaded, isEncryptionActive: $isEncryptionActive');
      
      if (isKeyUploaded && !isEncryptionActive) {
        trustScore -= 10;
        issues.add(const SecurityIssue(
          title: 'Encryption Not Active',
          description: 'Device encryption is waiting for approval. Key is uploaded.',
          severity: SecurityTrustLevel.warning,
        ));
        debugPrint('[TRUST] Encryption not active (waiting for trust), score -10');
      } else if (isEncryptionActive) {
        debugPrint('[TRUST] Encryption is ACTIVE - no deduction');
      }
      
      // Generate fingerprint from keyVersion if available - read FRESH
      final keyVersion = DeviceTrustStateManager.currentState.keyVersion ?? 'v1';
      final fingerprint = _formatFingerprint(keyVersion);
      
      final clampedScore = trustScore.clamp(0, 100);
      
      // Read final state for the status object
      final finalSessionState = DeviceTrustStateManager.currentState;
      
      setState(() {
        _securityStatus = SecurityStatusData(
          trustScore: clampedScore,
          issues: issues,
          keyVersion: keyVersion,
          fingerprint: fingerprint,
          isHmacVerified: finalSessionState.isKeyUploaded && privateKey != null,
          isSecureSendingEnabled: finalSessionState.isEncryptionActive,
        );
        _keyFingerprint = fingerprint;
        _isLoadingSecurity = false;
      });
      
      debugPrint('[SECURITY_UI] _loadSecurityStatus: COMPLETE');
      debugPrint('[STATUS] trustScore: $clampedScore, issues: ${issues.length}');
      for (final issue in issues) {
        debugPrint('[STATUS] Issue: ${issue.title}');
      }
    } catch (e) {
      debugPrint('[SECURITY_UI] _loadSecurityStatus: FAILED - $e');
      setState(() => _isLoadingSecurity = false);
    }
  }
  
  /// Format key version as fingerprint
  String _formatFingerprint(String keyVersion) {
    // Remove any non-alphanumeric characters
    final clean = keyVersion.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    // Pad or truncate to 16 characters
    final padded = clean.padRight(16, '0').substring(0, 16);
    // Format as XXXX-XXXX-XXXX-XXXX
    final formatted = '${padded.substring(0, 4)}-${padded.substring(4, 8)}-${padded.substring(8, 12)}-${padded.substring(12, 16)}';
    return formatted.toUpperCase();
  }
  
  void _showSecurityDetails() {
    showSecurityDetailsSheet(
      context,
      status: _securityStatus,
      onRevalidate: _revalidateKeys,
      onRotateKeys: _rotateKeys,
      onClearCache: _clearSecurityCache,
      currentUserId: FirebaseAuth.instance.currentUser?.uid,
    );
  }
  
  Future<void> _revalidateKeys() async {
    final colors = AppColors.of(context);
    
    if (!mounted) return;
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
            Text('Revalidating keys...'),
          ],
        ),
        backgroundColor: colors.accent,
        behavior: SnackBarBehavior.floating,
      ),
    );
    
    await _loadSecurityStatus();
    
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      
      if (_securityStatus.trustScore >= 80) {
        // Success case
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Keys revalidated successfully'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        // Failure case - show specific issues and actions
        final hasCriticalIssues = _securityStatus.issues.any(
          (issue) => issue.severity == SecurityTrustLevel.critical,
        );
        final primaryIssue = _securityStatus.issues.isNotEmpty 
            ? _securityStatus.issues.first 
            : null;
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      hasCriticalIssues ? Icons.error_outline : Icons.warning_amber,
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        hasCriticalIssues 
                            ? 'Key validation failed'
                            : 'Key validation incomplete',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                if (primaryIssue != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    primaryIssue.title,
                    style: const TextStyle(fontSize: 13),
                  ),
                  if (primaryIssue.description.isNotEmpty)
                    Text(
                      primaryIssue.description,
                      style: const TextStyle(fontSize: 12),
                    ),
                ],
                if (_securityStatus.issues.length > 1) ...[
                  const SizedBox(height: 4),
                  Text(
                    '+ ${_securityStatus.issues.length - 1} more issue(s)',
                    style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  _getActionForIssues(_securityStatus.issues),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
            backgroundColor: hasCriticalIssues ? Colors.red.shade700 : Colors.orange.shade700,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 8),
            action: SnackBarAction(
              label: 'DETAILS',
              textColor: Colors.white,
              onPressed: () {
                // Navigate to security details or show dialog
                _showSecurityIssuesDialog();
              },
            ),
          ),
        );
      }
    }
  }
  
  /// Returns actionable guidance based on the issues found
  String _getActionForIssues(List<SecurityIssue> issues) {
    if (issues.isEmpty) return 'Tap DETAILS to see status';
    
    final titles = issues.map((i) => i.title).toList();
    
    if (titles.contains('Private Key Missing')) {
      return 'Action: Log out and log back in to regenerate keys';
    }
    if (titles.contains('Public Key Missing')) {
      return 'Action: Check your internet connection and try again';
    }
    if (titles.contains('Device Approval Pending')) {
      return 'Action: Approve this device from another trusted device';
    }
    if (titles.contains('Encryption Not Active')) {
      return 'Action: Wait for device approval or contact support';
    }
    
    return 'Action: Check security details for next steps';
  }
  
  /// Shows a detailed dialog with all security issues
  void _showSecurityIssuesDialog() {
    final colors = AppColors.of(context);
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              Icons.security,
              color: _securityStatus.trustScore >= 80 
                  ? Colors.green 
                  : _securityStatus.trustScore >= 50 
                      ? Colors.orange 
                      : Colors.red,
            ),
            const SizedBox(width: 12),
            Text(
              'Security Status',
              style: TextStyle(color: colors.primaryText),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Trust score display
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _getTrustScoreColor().withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _getTrustScoreColor().withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: _getTrustScoreColor(),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '${_securityStatus.trustScore}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _getTrustScoreLabel(),
                            style: TextStyle(
                              color: _getTrustScoreColor(),
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _getTrustScoreDescription(),
                            style: TextStyle(
                              color: colors.secondaryText,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              
              // Issues list
              if (_securityStatus.issues.isNotEmpty) ...[
                Text(
                  'Issues Found (${_securityStatus.issues.length})',
                  style: TextStyle(
                    color: colors.primaryText,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                ..._securityStatus.issues.map((issue) => _buildIssueTile(issue, colors)),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle, color: Colors.green),
                      const SizedBox(width: 12),
                      Text(
                        'No issues found',
                        style: TextStyle(color: Colors.green),
                      ),
                    ],
                  ),
                ),
              ],
              
              const SizedBox(height: 20),
              
              // Recommended actions
              Text(
                'Recommended Actions',
                style: TextStyle(
                  color: colors.primaryText,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _getRecommendedActions(),
                style: TextStyle(
                  color: colors.secondaryText,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close', style: TextStyle(color: colors.accent)),
          ),
        ],
      ),
    );
  }
  
  Widget _buildIssueTile(SecurityIssue issue, AppColors colors) {
    final iconColor = issue.severity == SecurityTrustLevel.critical 
        ? Colors.red 
        : issue.severity == SecurityTrustLevel.warning 
            ? Colors.orange 
            : Colors.yellow;
    final icon = issue.severity == SecurityTrustLevel.critical 
        ? Icons.error 
        : issue.severity == SecurityTrustLevel.warning 
            ? Icons.warning 
            : Icons.info;
    
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: iconColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: iconColor.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  issue.title,
                  style: TextStyle(
                    color: colors.primaryText,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                if (issue.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    issue.description,
                    style: TextStyle(
                      color: colors.secondaryText,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  Color _getTrustScoreColor() {
    if (_securityStatus.trustScore >= 80) return Colors.green;
    if (_securityStatus.trustScore >= 50) return Colors.orange;
    return Colors.red;
  }
  
  String _getTrustScoreLabel() {
    if (_securityStatus.trustScore >= 80) return 'Secure';
    if (_securityStatus.trustScore >= 50) return 'At Risk';
    return 'Compromised';
  }
  
  String _getTrustScoreDescription() {
    if (_securityStatus.trustScore >= 80) {
      return 'Your encryption keys are valid and secure';
    } else if (_securityStatus.trustScore >= 50) {
      return 'Some security checks failed. Review issues below';
    } else {
      return 'Critical security issues detected. Immediate action required';
    }
  }
  
  String _getRecommendedActions() {
    final hasPrivateKeyIssue = _securityStatus.issues.any(
      (i) => i.title == 'Private Key Missing',
    );
    final hasPublicKeyIssue = _securityStatus.issues.any(
      (i) => i.title == 'Public Key Missing',
    );
    final hasApprovalIssue = _securityStatus.issues.any(
      (i) => i.title == 'Device Approval Pending' || i.title == 'Encryption Not Active',
    );
    
    final actions = <String>[];
    
    if (hasPrivateKeyIssue) {
      actions.add('1. Log out and log back in to regenerate your encryption keys');
    }
    if (hasPublicKeyIssue) {
      actions.add('${actions.length + 1}. Check your internet connection and wait for keys to sync');
    }
    if (hasApprovalIssue) {
      actions.add('${actions.length + 1}. Approve this device from another trusted device, or wait for approval');
    }
    if (actions.isEmpty) {
      actions.add('1. Try revalidating keys again');
      actions.add('2. If issues persist, contact support');
    }
    
    return actions.join('\n');
  }
  
  /// Retry uploading the public key to Firestore
  Future<void> _retryKeyUpload() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    
    setState(() => _isLoadingSecurity = true);
    
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
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
            Text('Uploading public key...'),
          ],
        ),
        backgroundColor: Colors.orange,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 10),
      ),
    );
    
    try {
      // Try to upload using AuthService
      await AuthService.retryPublicKeyUpload(user);
      
      // Mark key as uploaded in session manager
      // Get the key version from secure storage
      final keyStr = await AuthService.storage.read(key: 'private_key');
      if (keyStr != null) {
        final keyData = jsonDecode(keyStr) as Map<String, dynamic>;
        final keyVersion = keyData['n']?.toString().substring(0, 8) ?? 'v1';
        DeviceTrustStateManager.markKeyUploaded(keyVersion);
        debugPrint('[Settings] _retryKeyUpload: Session state updated - key marked as uploaded');
      }
      
      // Wait a moment for session state to propagate
      await Future.delayed(const Duration(milliseconds: 500));
      
      // Reload security status to check if upload succeeded
      await _loadSecurityStatus();
      
      if (!mounted) return;
      
      // Show result
      if (_securityStatus.trustScore >= 80) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Public key uploaded successfully!'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else if (_hasPendingKeyUpload) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Upload failed. Please check your connection and try again.'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      debugPrint('[Settings] _retryKeyUpload: ERROR - $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Upload failed: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoadingSecurity = false);
      }
    }
  }
  
  Future<void> _rotateKeys() async {
    final colors = AppColors.of(context);
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Rotate Keys?', style: TextStyle(color: colors.primaryText)),
         content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will generate new encryption keys for your account.',
              style: TextStyle(color: colors.secondaryText),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.orange.shade700, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Important',
                        style: TextStyle(
                          color: Colors.orange.shade900,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '• Your device will keep old keys to read past messages',
                    style: TextStyle(color: Colors.orange.shade800, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '• Other devices may not decrypt messages sent to you',
                    style: TextStyle(color: Colors.orange.shade800, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '• Old messages you sent remain readable on all devices',
                    style: TextStyle(color: Colors.orange.shade800, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: TextStyle(color: colors.accent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Rotate', style: TextStyle(color: Colors.orange)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await AuthService.rotateKeys(context);
      await _loadSecurityStatus();
    }
  }
  
  Future<void> _clearSecurityCache() async {
    final prefs = await SharedPreferences.getInstance();
    // Clear only security-related cache
    await prefs.remove('security_cache');
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Security cache cleared'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _loadSettings() async {
    debugPrint('[Settings] _loadSettings: START');
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _isDarkMode = prefs.getBool('darkMode') ?? false;
      _notificationsEnabled = prefs.getBool('notifications') ?? true;
      _messagePreview = prefs.getBool('messagePreview') ?? true;
      _soundEnabled = prefs.getBool('sound') ?? true;
      _vibrationEnabled = prefs.getBool('vibration') ?? true;
      _isLoading = false;
    });
    debugPrint('[Settings] _loadSettings: COMPLETE, darkMode=$_isDarkMode');
  }

  Future<void> _saveSetting(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  void _toggle(String key, bool value, Function(bool) setter) {
    debugPrint('[Settings] _toggle: $key=$value');
    setState(() => setter(value));
    _saveSetting(key, value);
  }

  Future<void> _launchUrl(String urlString) async {
    debugPrint('[Settings] _launchUrl: url=$urlString');
    try {
      final url = Uri.parse(urlString);
      await launchUrl(url, mode: LaunchMode.externalApplication);
      debugPrint('[Settings] _launchUrl: SUCCESS');
    } catch (_) {
      debugPrint('[Settings] _launchUrl: FAILED');
      if (mounted) _showSnack('Could not open link', Colors.red);
    }
  }

  void _showSnack(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _clearCacheOnly() async {
    debugPrint('[Settings] _clearCacheOnly: START');
    final prefs = await SharedPreferences.getInstance();

    final darkMode = prefs.getBool('darkMode') ?? false;
    final notifications = prefs.getBool('notifications') ?? true;
    final messagePreview = prefs.getBool('messagePreview') ?? true;
    final sound = prefs.getBool('sound') ?? true;
    final vibration = prefs.getBool('vibration') ?? true;

    await prefs.clear();

    await prefs.setBool('darkMode', darkMode);
    await prefs.setBool('notifications', notifications);
    await prefs.setBool('messagePreview', messagePreview);
    await prefs.setBool('sound', sound);
    await prefs.setBool('vibration', vibration);

    themeNotifier.value = darkMode ? ThemeMode.dark : ThemeMode.light;
    debugPrint('[Settings] _clearCacheOnly: COMPLETE');
  }

  void _showClearCacheDialog(AppColors colors) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Clear Cache', style: TextStyle(color: colors.primaryText)),
        content: Text(
          'This will clear your local message cache. '
          'Your messages are safe on the server. '
          'Your settings and preferences will be kept.',
          style: TextStyle(color: colors.secondaryText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: colors.accent)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _clearCacheOnly();
              if (mounted) {
                _showSnack('Cache cleared successfully', Colors.green);
                _loadSettings();
              }
            },
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return Scaffold(
      backgroundColor: colors.screenBg,
      appBar: AppBar(
        backgroundColor: colors.appBarBg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.primaryText),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Settings',
          style: TextStyle(
            color: colors.primaryText,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: colors.accent))
          : RefreshIndicator(
              onRefresh: () async {
                debugPrint('[Settings] Pull-to-refresh triggered');
                await _loadSecurityStatus();
              },
              color: colors.accent,
              backgroundColor: colors.cardBg,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  const SizedBox(height: 8),
                  _buildSectionHeader(
                    icon: Icons.palette_outlined,
                    title: 'Appearance',
                    color: colors.accent,
                  colors: colors,
                ),
                const SizedBox(height: 10),
                _buildSettingsCard(
                  colors: colors,
                  children: [
                    _buildSwitchTile(
                      icon: Icons.dark_mode_outlined,
                      iconColor: const Color(0xFF6366F1),
                      title: 'Dark Mode',
                      subtitle: 'Switch to dark theme',
                      value: _isDarkMode,
                      colors: colors,
                      onChanged: (v) {
                        _toggle('darkMode', v, (val) => _isDarkMode = val);
                        themeNotifier.value = v
                            ? ThemeMode.dark
                            : ThemeMode.light;
                      },
                      isLast: true,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildSectionHeader(
                  icon: Icons.notifications_outlined,
                  title: 'Notifications',
                  color: const Color(0xFFEF4444),
                  colors: colors,
                ),
                const SizedBox(height: 10),
                _buildSettingsCard(
                  colors: colors,
                  children: [
                    _buildSwitchTile(
                      icon: Icons.notifications_active_outlined,
                      iconColor: const Color(0xFFEF4444),
                      title: 'Push Notifications',
                      subtitle: 'Receive message alerts',
                      value: _notificationsEnabled,
                      colors: colors,
                      onChanged: (v) {
                        _toggle(
                          'notifications',
                          v,
                          (val) => _notificationsEnabled = val,
                        );
                      },
                    ),
                    _buildDivider(colors),
                    _buildSwitchTile(
                      icon: Icons.message_outlined,
                      iconColor: const Color(0xFF8B5CF6),
                      title: 'Sender Preview',
                      subtitle: 'Show sender name in notifications',
                      value: _messagePreview,
                      colors: colors,
                      onChanged: _notificationsEnabled
                          ? (v) => _toggle(
                              'messagePreview',
                              v,
                              (val) => _messagePreview = val,
                            )
                          : null,
                    ),
                    _buildDivider(colors),
                    _buildSwitchTile(
                      icon: Icons.volume_up_outlined,
                      iconColor: const Color(0xFF22C55E),
                      title: 'Sound',
                      subtitle: 'Play sound for new messages',
                      value: _soundEnabled,
                      colors: colors,
                      onChanged: _notificationsEnabled
                          ? (v) => _toggle(
                              'sound',
                              v,
                              (val) => _soundEnabled = val,
                            )
                          : null,
                    ),
                    _buildDivider(colors),
                    _buildSwitchTile(
                      icon: Icons.vibration,
                      iconColor: const Color(0xFFF59E0B),
                      title: 'Vibration',
                      subtitle: 'Vibrate for new messages',
                      value: _vibrationEnabled,
                      colors: colors,
                      onChanged: _notificationsEnabled
                          ? (v) => _toggle(
                              'vibration',
                              v,
                              (val) => _vibrationEnabled = val,
                            )
                          : null,
                      isLast: true,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildSectionHeader(
                  icon: Icons.lock_outline,
                  title: 'Privacy & Security',
                  color: const Color(0xFF22C55E),
                  colors: colors,
                ),
                const SizedBox(height: 10),
                _buildSettingsCard(
                  colors: colors,
                  children: [
                    // Security Status Indicator (full mode) - display only, not clickable
                    if (!_isLoadingSecurity)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: SecurityStatusIndicator(
                          status: _securityStatus,
                          compact: false,
                          showIssuesCount: true,
                          // onTap removed - only clickable via "View Security Details" button below
                        ),
                      ),
                    if (!_isLoadingSecurity)
                      _buildDivider(colors),
                    // Key Fingerprint Display
                    if (!_isLoadingSecurity && _keyFingerprint != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: KeyFingerprintDisplay(
                          fingerprint: _keyFingerprint!,
                          label: 'Your Key Fingerprint',
                          showQrCode: true,
                          showVerifyButton: true,
                          onVerify: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Compare this fingerprint with your contact to verify identity'),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                        ),
                      ),
                    if (!_isLoadingSecurity && _keyFingerprint != null)
                      _buildDivider(colors),
                    // Key Upload Status - always visible
                    if (!_isLoadingSecurity)
                      Builder(
                        builder: (context) {
                          final sessionState = DeviceTrustStateManager.currentState;
                          final bool isUploaded = sessionState.isKeyUploaded;
                          
                          return _buildNavTile(
                            icon: isUploaded ? Icons.cloud_done : Icons.cloud_upload_outlined,
                            iconColor: isUploaded ? const Color(0xFF22C55E) : Colors.orange,
                            title: isUploaded ? 'Public Key Uploaded' : 'Upload Public Key',
                            subtitle: isUploaded 
                                ? 'Your public key is synced to the cloud'
                                : 'Upload your public key to enable encryption',
                            colors: colors,
                            trailing: isUploaded
                                ? Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.green.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: Colors.green.withValues(alpha: 0.3),
                                      ),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.check_circle,
                                          size: 14,
                                          color: Color(0xFF22C55E),
                                        ),
                                        SizedBox(width: 4),
                                        Text(
                                          'Synced',
                                          style: TextStyle(
                                            color: Color(0xFF22C55E),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : const Icon(
                                    Icons.arrow_forward_ios,
                                    size: 16,
                                    color: Colors.grey,
                                  ),
                            onTap: isUploaded ? null : _retryKeyUpload,
                          );
                        },
                      ),
                    if (!_isLoadingSecurity)
                      _buildDivider(colors),
                    _buildNavTile(
                      icon: Icons.lock_outline,
                      iconColor: const Color(0xFF22C55E),
                      title: 'End-to-End Encryption',
                      subtitle: 'All messages are encrypted',
                      colors: colors,
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.green.withValues(alpha: 0.3),
                          ),
                        ),
                        child: const Text(
                          'Active',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.green,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      onTap: null,
                    ),
                    _buildDivider(colors),
                    // Revalidate Keys button
                    _buildNavTile(
                      icon: Icons.refresh,
                      iconColor: colors.accent,
                      title: 'Revalidate Keys',
                      subtitle: 'Verify your encryption keys',
                      colors: colors,
                      onTap: _revalidateKeys,
                    ),
                    _buildDivider(colors),
                    // View Security Details button
                    _buildNavTile(
                      icon: Icons.security,
                      iconColor: const Color(0xFF6366F1),
                      title: 'View Security Details',
                      subtitle: 'Session info, key versions, and more',
                      colors: colors,
                      onTap: _showSecurityDetails,
                    ),
                    _buildDivider(colors),
                    _buildNavTile(
                      icon: Icons.delete_outline,
                      iconColor: Colors.red,
                      title: 'Clear All Chats',
                      subtitle: 'Delete all local message cache',
                      colors: colors,
                      onTap: () => _showClearCacheDialog(colors),
                    ),
                    _buildDivider(colors),
                    _buildNavTile(
                      icon: Icons.key_outlined,
                      iconColor: const Color(0xFFF59E0B),
                      title: 'Rotate Keys',
                      subtitle: 'Generate new encryption keys',
                      colors: colors,
                      onTap: () => _rotateKeys(),
                    ),
                    _buildDivider(colors),
                    _buildNavTile(
                      icon: Icons.devices_outlined,
                      iconColor: const Color(0xFF8B5CF6),
                      title: 'Linked Devices',
                      subtitle: 'Manage your trusted devices',
                      colors: colors,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const LinkedDevicesScreen(),
                          ),
                        );
                      },
                      isLast: true,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildSectionHeader(
                  icon: Icons.info_outline,
                  title: 'About',
                  color: colors.secondaryText,
                  colors: colors,
                ),
                const SizedBox(height: 10),
                _buildSettingsCard(
                  colors: colors,
                  children: [
                    _buildNavTile(
                      icon: Icons.shield_outlined,
                      iconColor: colors.accent,
                      title: 'Privacy Policy',
                      subtitle: 'How we handle your data',
                      colors: colors,
                      onTap: () => _launchUrl('https://yourapp.com/privacy'),
                    ),
                    _buildDivider(colors),
                    _buildNavTile(
                      icon: Icons.description_outlined,
                      iconColor: const Color(0xFF6366F1),
                      title: 'Terms of Service',
                      subtitle: 'Our terms and conditions',
                      colors: colors,
                      onTap: () => _launchUrl('https://yourapp.com/terms'),
                    ),
                    _buildDivider(colors),
                    _buildNavTile(
                      icon: Icons.info_outline,
                      iconColor: colors.secondaryText,
                      title: 'App Version',
                      subtitle: '1.0.0',
                      colors: colors,
                      onTap: null,
                      isLast: true,
                    ),
                  ],
                ),
                const SizedBox(height: 40),
                
                // Account Section
                _buildSectionHeader(
                  icon: Icons.account_circle_outlined,
                  title: 'Account',
                  color: Colors.red,
                  colors: colors,
                ),
                const SizedBox(height: 10),
                _buildSettingsCard(
                  colors: colors,
                  children: [
                    _buildNavTile(
                      icon: Icons.logout,
                      iconColor: Colors.red,
                      title: 'Log Out',
                      subtitle: 'Sign out of your account',
                      colors: colors,
                      onTap: () => _showLogoutDialog(colors),
                      isLast: true,
                    ),
                  ],
                ),
                const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }

  Future<void> _showLogoutDialog(AppColors colors) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Log Out?', style: TextStyle(color: colors.primaryText)),
        content: Text(
          'Are you sure you want to log out?',
          style: TextStyle(color: colors.secondaryText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('Cancel', style: TextStyle(color: colors.secondaryText)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );
    
    if (confirm == true && mounted) {
      await AuthService.logout(context);
      if (mounted) {
        Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
      }
    }
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required Color color,
    required AppColors colors,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsCard({
    required List<Widget> children,
    required AppColors colors,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
    required AppColors colors,
    bool isLast = false,
  }) {
    final isDisabled = onChanged == null;

    return Opacity(
      opacity: isDisabled ? 0.45 : 1.0,
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 8,
          top: 4,
          bottom: isLast ? 4 : 0,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 18),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: colors.primaryText,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: colors.secondaryText),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: colors.accent,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
    required AppColors colors,
    Widget? trailing,
    bool isLast = false,
  }) {

    return InkWell(
      onTap: onTap,
      borderRadius: isLast
          ? const BorderRadius.vertical(bottom: Radius.circular(16))
          : BorderRadius.zero,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: isLast ? 14 : 12,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 18),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: colors.primaryText,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: colors.secondaryText),
                  ),
                ],
              ),
            ),
            trailing ??
                (onTap != null
                    ? Icon(
                        Icons.chevron_right,
                        color: colors.secondaryText,
                        size: 20,
                      )
                    : const SizedBox()),
          ],
        ),
      ),
    );
  }

  Widget _buildDivider(AppColors colors) {
    return Padding(
      padding: const EdgeInsets.only(left: 66),
      child: Divider(height: 1, color: colors.divider),
    );
  }
}

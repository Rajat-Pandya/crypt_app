import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/device_service.dart';
import '../services/device_trust_service.dart';
import '../services/session_lifecycle_manager.dart';

/// Screen for managing linked devices and approving new devices.
///
/// Shows:
/// - List of all devices
/// - Pending approval requests
/// - Option to revoke devices
/// - Option to generate OTP for new device approval
class LinkedDevicesScreen extends StatefulWidget {
  const LinkedDevicesScreen({super.key});

  @override
  State<LinkedDevicesScreen> createState() => _LinkedDevicesScreenState();
}

class _LinkedDevicesScreenState extends State<LinkedDevicesScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<DeviceInfo> _devices = [];
  List<Map<String, dynamic>> _pendingApprovals = [];
  SessionMetadata? _currentSession;
  bool _isLoading = true;
  String? _generatedOTP;
  bool _isGeneratingOTP = false;

  Timer? _otpExpiryTimer;
  int _otpExpirySeconds = 0;

  StreamSubscription? _approvalSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData();
    _listenForApprovals();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _otpExpiryTimer?.cancel();
    _approvalSubscription?.cancel();
    super.dispose();
  }

  void _listenForApprovals() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // Poll for new approval requests every 5 seconds
    _approvalSubscription =
        Stream.periodic(const Duration(seconds: 5)).asyncMap((_) async {
      return DeviceService.getPendingApprovals(user);
    }).listen((approvals) {
      if (mounted) {
        setState(() {
          _pendingApprovals = approvals;
        });
      }
    });
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        _showError('Not logged in');
        return;
      }

      // Load devices
      final devices = await DeviceService.getAllDevices(user);
      setState(() {
        _devices = devices;
      });

      // Load pending approvals
      final approvals = await DeviceService.getPendingApprovals(user);
      setState(() {
        _pendingApprovals = approvals;
      });

      // Load current session
      _currentSession = SessionLifecycleManager.currentSession;
    } catch (e) {
      _showError('Failed to load devices: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _generateOTP() async {
    setState(() => _isGeneratingOTP = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final otp = await DeviceTrustService.generateOTP(user);
      if (otp != null) {
        setState(() {
          _generatedOTP = otp;
          _otpExpirySeconds = 600; // 10 minutes
        });

        // Start expiry countdown
        _otpExpiryTimer?.cancel();
        _otpExpiryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          setState(() {
            _otpExpirySeconds--;
            if (_otpExpirySeconds <= 0) {
              _generatedOTP = null;
              timer.cancel();
            }
          });
        });
      } else {
        _showError('Failed to generate code');
      }
    } catch (e) {
      _showError('Failed to generate code: $e');
    } finally {
      if (mounted) setState(() => _isGeneratingOTP = false);
    }
  }

  Future<void> _approveDevice(String deviceId) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final success = await DeviceService.approveDevice(
        user: user,
        deviceIdToApprove: deviceId,
      );

      if (success) {
        _showSuccess('Device approved');
        _loadData();
      } else {
        _showError('Failed to approve device');
      }
    } catch (e) {
      _showError('Failed to approve device: $e');
    }
  }

  Future<void> _rejectDevice(String deviceId) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final success = await DeviceService.rejectDevice(
        user: user,
        deviceIdToReject: deviceId,
        reason: 'rejected_by_user',
      );

      if (success) {
        _showSuccess('Device rejected');
        _loadData();
      } else {
        _showError('Failed to reject device');
      }
    } catch (e) {
      _showError('Failed to reject device: $e');
    }
  }

  Future<void> _revokeDevice(String deviceId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Revoke Device?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'This device will no longer be able to access your encrypted messages.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      await DeviceService.revokeDevice(
        user: user,
        deviceId: deviceId,
      );

      _showSuccess('Device revoked');
      _loadData();
    } catch (e) {
      _showError('Failed to revoke device: $e');
    }
  }

  Future<void> _unrevokeDevice(String deviceId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Restore Device?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'This device will be un-revoked and can be approved again.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore', style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      await DeviceService.unrevokeDevice(
        user: user,
        deviceId: deviceId,
      );

      _showSuccess('Device restored. The device can now be approved again.');
      _loadData();
    } catch (e) {
      _showError('Failed to restore device: $e');
    }
  }

  Future<void> _deleteDevice(String deviceId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Row(
          children: [
            Icon(Icons.warning, color: Colors.red),
            SizedBox(width: 8),
            Text('Delete Device?', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: const Text(
          'This will permanently remove this device from your account.\n\n'
          'The device will need to be re-added if you want to use it again.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      await DeviceService.deleteDevice(
        user: user,
        deviceId: deviceId,
      );

      _showSuccess('Device deleted');
      _loadData();
    } catch (e) {
      _showError('Failed to delete device: $e');
    }
  }

  Future<void> _approveDeviceFromHere(String deviceId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Approve Device?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Approve this device to access your encrypted messages.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Approve', style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      // Check if current device is trusted
      final isTrusted = await DeviceService.isCurrentDeviceTrusted(user);
      if (!isTrusted) {
        _showError('Your current device must be trusted to approve other devices');
        return;
      }

      final success = await DeviceService.approveDevice(
        user: user,
        deviceIdToApprove: deviceId,
      );

      if (success) {
        _showSuccess('Device approved successfully!');
        _loadData();
      } else {
        _showError('Failed to approve device');
      }
    } catch (e) {
      _showError('Failed to approve device: $e');
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: const Text(
          'Linked Devices',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: _loadData,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.orange,
          labelColor: Colors.orange,
          unselectedLabelColor: Colors.white60,
          tabs: [
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Devices'),
                  if (_pendingApprovals.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${_pendingApprovals.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Tab(text: 'Add Device'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.orange),
            )
          : TabBarView(
              controller: _tabController,
              children: [
                _buildDevicesTab(),
                _buildAddDeviceTab(),
              ],
            ),
    );
  }

  Widget _buildDevicesTab() {
    if (_devices.isEmpty) {
      return const Center(
        child: Text(
          'No devices found',
          style: TextStyle(color: Colors.white60),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      color: Colors.orange,
      backgroundColor: const Color(0xFF1E293B),
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _devices.length + (_pendingApprovals.isNotEmpty ? 1 : 0),
        itemBuilder: (context, index) {
          if (index < _pendingApprovals.length) {
            return _buildPendingApprovalCard(_pendingApprovals[index]);
          }

          final deviceIndex = index - (_pendingApprovals.isNotEmpty ? _pendingApprovals.length : 0);
          return _buildDeviceCard(_devices[deviceIndex]);
        },
      ),
    );
  }

  Widget _buildPendingApprovalCard(Map<String, dynamic> approval) {
    final deviceName = approval['deviceName'] ?? 'Unknown Device';
    final platform = approval['platform'] ?? 'unknown';
    final deviceId = approval['deviceId'] ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _getPlatformIcon(platform),
                color: Colors.orange,
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      deviceName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Waiting for approval',
                      style: TextStyle(
                        color: Colors.orange.withOpacity(0.8),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _approveDevice(deviceId),
                  icon: const Icon(Icons.check_circle, size: 18),
                  label: const Text('Approve'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _rejectDevice(deviceId),
                  icon: const Icon(Icons.cancel, size: 18),
                  label: const Text('Reject'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.withOpacity(0.8),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceCard(DeviceInfo device) {
    final deviceName = device.deviceName;
    final platform = device.platform;
    final trusted = device.trusted;
    final revoked = device.revoked;
    final lastSeen = device.lastSeen;
    final createdAt = device.createdAt;
    final isCurrentDevice = device.deviceId == _currentSession?.deviceId;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCurrentDevice
              ? Colors.orange.withOpacity(0.5)
              : Colors.white10,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: revoked
                      ? Colors.red.withOpacity(0.2)
                      : trusted
                          ? Colors.green.withOpacity(0.2)
                          : Colors.orange.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _getPlatformIcon(platform),
                  color: revoked
                      ? Colors.red
                      : trusted
                          ? Colors.green
                          : Colors.orange,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '$deviceName${isCurrentDevice ? ' (This device)' : ''}',
                            style: TextStyle(
                              color: isCurrentDevice
                                  ? Colors.orange
                                  : Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: revoked
                                ? Colors.red.withOpacity(0.2)
                                : trusted
                                    ? Colors.green.withOpacity(0.2)
                                    : Colors.orange.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            revoked
                                ? 'Revoked'
                                : trusted
                                    ? 'Trusted'
                                    : 'Pending',
                            style: TextStyle(
                              color: revoked
                                  ? Colors.red
                                  : trusted
                                      ? Colors.green
                                      : Colors.orange,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (lastSeen != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Last seen: ${_formatDateTime(lastSeen)}',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          // Action buttons based on device status
          if (!isCurrentDevice) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Delete button (always available for cleanup)
                TextButton.icon(
                  onPressed: () => _deleteDevice(device.deviceId),
                  icon: const Icon(Icons.delete_outline, color: Colors.grey, size: 18),
                  label: const Text(
                    'Remove',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                // Revoke/Un-revoke button
                if (revoked)
                  TextButton.icon(
                    onPressed: () => _unrevokeDevice(device.deviceId),
                    icon: const Icon(Icons.restore, color: Colors.green, size: 18),
                    label: const Text(
                      'Restore',
                      style: TextStyle(color: Colors.green, fontSize: 13),
                    ),
                  )
                else if (!trusted)
                  TextButton.icon(
                    onPressed: () => _approveDeviceFromHere(device.deviceId),
                    icon: const Icon(Icons.check_circle, color: Colors.orange, size: 18),
                    label: const Text(
                      'Approve',
                      style: TextStyle(color: Colors.orange, fontSize: 13),
                    ),
                  )
                else
                  TextButton.icon(
                    onPressed: () => _revokeDevice(device.deviceId),
                    icon: const Icon(Icons.logout, color: Colors.red, size: 18),
                    label: const Text(
                      'Revoke',
                      style: TextStyle(color: Colors.red, fontSize: 13),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAddDeviceTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const SizedBox(height: 20),
          // Info card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blue.withOpacity(0.3)),
            ),
            child: Column(
              children: [
                const Icon(Icons.info_outline, color: Colors.blue, size: 32),
                const SizedBox(height: 12),
                const Text(
                  'Add a New Device',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'To add a new device:\n\n1. Install the app on your new device\n2. Log in with your account\n3. Enter the 6-digit code below on the new device\n\nOr approve from this device when prompted.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // OTP Section
          if (_generatedOTP != null) ...[
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.green.withOpacity(0.3)),
              ),
              child: Column(
                children: [
                  const Text(
                    'Your Code',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: _generatedOTP!));
                      _showSuccess('Code copied to clipboard');
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withAlpha(51)),
                      ),
                      child: Text(
                        _generatedOTP!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 8,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Expires in ${_otpExpirySeconds ~/ 60}:${(_otpExpirySeconds % 60).toString().padLeft(2, '0')}',
                    style: TextStyle(
                      color: _otpExpirySeconds < 60 ? Colors.red : Colors.orange,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Tap to copy',
                    style: TextStyle(
                      color: Color(0x80FFFFFF),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _isGeneratingOTP ? null : _generateOTP,
              icon: _isGeneratingOTP
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.refresh, size: 20),
              label: const Text('Generate New Code'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white.withOpacity(0.1),
                foregroundColor: Colors.white70,
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 32),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ] else ...[
            ElevatedButton.icon(
              onPressed: _isGeneratingOTP ? null : _generateOTP,
              icon: _isGeneratingOTP
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.add_circle_outline, size: 24),
              label: const Text(
                'Generate Code',
                style: TextStyle(fontSize: 16),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 40),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _getPlatformIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'android':
        return Icons.android;
      case 'ios':
        return Icons.apple;
      case 'web':
        return Icons.web;
      case 'windows':
        return Icons.desktop_windows;
      case 'macos':
        return Icons.laptop_mac;
      case 'linux':
        return Icons.computer;
      default:
        return Icons.device_unknown;
    }
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inSeconds < 60) {
      return 'Just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
    }
  }
}

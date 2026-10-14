import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../main.dart';

/// Security trust level indicator
enum SecurityTrustLevel {
  good,
  warning,
  critical,
}

/// Security issue data model
class SecurityIssue {
  final String title;
  final String description;
  final SecurityTrustLevel severity;
  final DateTime? timestamp;

  const SecurityIssue({
    required this.title,
    required this.description,
    this.severity = SecurityTrustLevel.warning,
    this.timestamp,
  });
}

/// Security status data model
class SecurityStatusData {
  final int trustScore;
  final List<SecurityIssue> issues;
  final DateTime? sessionCreated;
  final DateTime? lastActivity;
  final String? keyVersion;
  final String? fingerprint;
  final bool isHmacVerified;
  final bool isSecureSendingEnabled;

  const SecurityStatusData({
    required this.trustScore,
    this.issues = const [],
    this.sessionCreated,
    this.lastActivity,
    this.keyVersion,
    this.fingerprint,
    this.isHmacVerified = false,
    this.isSecureSendingEnabled = false,
  });

  SecurityTrustLevel get trustLevel {
    if (trustScore >= 80) return SecurityTrustLevel.good;
    if (trustScore >= 50) return SecurityTrustLevel.warning;
    return SecurityTrustLevel.critical;
  }
}

/// Shows trust score as a colored indicator with optional details
/// 
/// Features:
/// - Colored indicator (green=good, yellow=warning, red=critical)
/// - Trust score percentage display
/// - Security issues count
/// - Tap to show details
/// - Compact mode for app bar, full mode for settings
class SecurityStatusIndicator extends StatelessWidget {
  final SecurityStatusData status;
  final bool compact;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showIssuesCount;
  final bool animated;

  const SecurityStatusIndicator({
    super.key,
    required this.status,
    this.compact = false,
    this.onTap,
    this.onLongPress,
    this.showIssuesCount = true,
    this.animated = true,
  });

  @override
  Widget build(BuildContext context) {
    debugPrint('[SecurityStatusIndicator] build: Building - trustScore: ${status.trustScore}, trustLevel: ${status.trustLevel}, issues: ${status.issues.length}');
    final colors = AppColors.of(context);

    return Semantics(
      label: _getSemanticLabel(),
      button: onTap != null,
      child: GestureDetector(
        onTap: () {
          debugPrint('[SecurityStatusIndicator] onTap: User tapped security indicator');
          onTap?.call();
        },
        onLongPress: () {
          debugPrint('[SecurityStatusIndicator] onLongPress: User long pressed security indicator');
          onLongPress?.call();
        },
        child: compact ? _buildCompactView(colors) : _buildFullView(colors),
      ),
    );
  }

  String _getSemanticLabel() {
    debugPrint('[SecurityStatusIndicator] _getSemanticLabel: Generating semantic label');
    final buffer = StringBuffer();
    buffer.write('Security status: ${status.trustScore}% trust score. ');
    buffer.write(_getTrustLevelText());
    if (status.issues.isNotEmpty) {
      buffer.write('. ${status.issues.length} security issues detected');
    }
    return buffer.toString();
  }

  String _getTrustLevelText() {
    switch (status.trustLevel) {
      case SecurityTrustLevel.good:
        return 'Security level is good';
      case SecurityTrustLevel.warning:
        return 'Security level is warning';
      case SecurityTrustLevel.critical:
        return 'Security level is critical';
    }
  }

  Widget _buildCompactView(AppColors colors) {
    debugPrint('[SecurityStatusIndicator] _buildCompactView: Building compact view');
    return Tooltip(
      message: '${status.trustScore}% Trust Score${_getIssuesTooltip()}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: _getBackgroundColor(colors).withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _getBorderColor(colors).withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildIndicatorDot(size: 8),
            const SizedBox(width: 4),
            Text(
              '${status.trustScore}%',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: _getTextColor(colors),
              ),
            ),
            if (showIssuesCount && status.issues.isNotEmpty) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${status.issues.length}',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Colors.red,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFullView(AppColors colors) {
    debugPrint('[SecurityStatusIndicator] _buildFullView: Building full view');
    return Container(
      padding: const EdgeInsets.all(16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _buildIndicatorDot(size: 12),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Trust Score',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: colors.secondaryText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${status.trustScore}%',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: _getTextColor(colors),
                      ),
                    ),
                  ],
                ),
              ),
              if (showIssuesCount && status.issues.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: Colors.red,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${status.issues.length} Issues',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.red,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          _buildProgressBar(colors),
          if (status.issues.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildIssuesList(colors),
          ],
        ],
      ),
    );
  }

  Widget _buildIndicatorDot({required double size}) {
    return animated
        ? TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 300),
            tween: Tween(begin: 0, end: 1),
            builder: (context, value, child) {
              return Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: _getIndicatorColor(),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _getIndicatorColor().withValues(alpha: 0.4 * value),
                      blurRadius: 4 * value,
                      spreadRadius: 2 * value,
                    ),
                  ],
                ),
              );
            },
          )
        : Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: _getIndicatorColor(),
              shape: BoxShape.circle,
            ),
          );
  }

  Widget _buildProgressBar(AppColors colors) {
    debugPrint('[SecurityStatusIndicator] _buildProgressBar: Building progress bar - trustScore: ${status.trustScore}');
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Container(
              height: 8,
              decoration: BoxDecoration(
                color: colors.inputBg,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            animated
                ? TweenAnimationBuilder<double>(
                    duration: const Duration(milliseconds: 800),
                    curve: Curves.easeOutCubic,
                    tween: Tween(begin: 0, end: status.trustScore / 100),
                    builder: (context, value, child) {
                      return Container(
                        height: 8,
                        width: constraints.maxWidth * value,
                        decoration: BoxDecoration(
                          color: _getIndicatorColor(),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      );
                    },
                  )
                : Container(
                    height: 8,
                    width: constraints.maxWidth * (status.trustScore / 100),
                    decoration: BoxDecoration(
                      color: _getIndicatorColor(),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
          ],
        );
      },
    );
  }

  Widget _buildIssuesList(AppColors colors) {
    debugPrint('[SecurityStatusIndicator] _buildIssuesList: Building issues list - count: ${status.issues.length}');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: status.issues.take(3).map((issue) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _getIssueIcon(issue.severity),
                size: 16,
                color: _getIssueColor(issue.severity),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      issue.title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: colors.primaryText,
                      ),
                    ),
                    if (issue.description.isNotEmpty)
                      Text(
                        issue.description,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.secondaryText,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Color _getIndicatorColor() {
    debugPrint('[SecurityStatusIndicator] _getIndicatorColor: Getting color for trustLevel: ${status.trustLevel}');
    switch (status.trustLevel) {
      case SecurityTrustLevel.good:
        return Colors.green;
      case SecurityTrustLevel.warning:
        return Colors.orange;
      case SecurityTrustLevel.critical:
        return Colors.red;
    }
  }

  Color _getBackgroundColor(AppColors colors) {
    switch (status.trustLevel) {
      case SecurityTrustLevel.good:
        return Colors.green;
      case SecurityTrustLevel.warning:
        return Colors.orange;
      case SecurityTrustLevel.critical:
        return Colors.red;
    }
  }

  Color _getBorderColor(AppColors colors) {
    switch (status.trustLevel) {
      case SecurityTrustLevel.good:
        return Colors.green;
      case SecurityTrustLevel.warning:
        return Colors.orange;
      case SecurityTrustLevel.critical:
        return Colors.red;
    }
  }

  Color _getTextColor(AppColors colors) {
    switch (status.trustLevel) {
      case SecurityTrustLevel.good:
        return Colors.green;
      case SecurityTrustLevel.warning:
        return Colors.orange;
      case SecurityTrustLevel.critical:
        return Colors.red;
    }
  }

  IconData _getIssueIcon(SecurityTrustLevel severity) {
    switch (severity) {
      case SecurityTrustLevel.good:
        return Icons.check_circle;
      case SecurityTrustLevel.warning:
        return Icons.warning_amber;
      case SecurityTrustLevel.critical:
        return Icons.error;
    }
  }

  Color _getIssueColor(SecurityTrustLevel severity) {
    switch (severity) {
      case SecurityTrustLevel.good:
        return Colors.green;
      case SecurityTrustLevel.warning:
        return Colors.orange;
      case SecurityTrustLevel.critical:
        return Colors.red;
    }
  }

  String _getIssuesTooltip() {
    if (status.issues.isEmpty) return '';
    return '\n${status.issues.length} issue${status.issues.length == 1 ? '' : 's'}';
  }
}

/// Displays a key fingerprint in XXXX-XXXX-XXXX-XXXX format
/// 
/// Features:
/// - Copy to clipboard button
/// - QR code generation option
/// - Verification button to compare fingerprints
class KeyFingerprintDisplay extends StatefulWidget {
  final String fingerprint;
  final bool showCopyButton;
  final bool showQrCode;
  final bool showVerifyButton;
  final VoidCallback? onVerify;
  final String? label;
  final bool compact;

  const KeyFingerprintDisplay({
    super.key,
    required this.fingerprint,
    this.showCopyButton = true,
    this.showQrCode = true,
    this.showVerifyButton = true,
    this.onVerify,
    this.label,
    this.compact = false,
  });

  @override
  State<KeyFingerprintDisplay> createState() => _KeyFingerprintDisplayState();
}

class _KeyFingerprintDisplayState extends State<KeyFingerprintDisplay>
    with SingleTickerProviderStateMixin {
  bool _showQr = false;
  late AnimationController _qrAnimationController;
  late Animation<double> _qrAnimation;

  @override
  void initState() {
    debugPrint('[KeyFingerprintDisplay] initState: START');
    super.initState();
    _qrAnimationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _qrAnimation = CurvedAnimation(
      parent: _qrAnimationController,
      curve: Curves.easeOutCubic,
    );
    debugPrint('[KeyFingerprintDisplay] initState: END');
  }

  @override
  void dispose() {
    debugPrint('[KeyFingerprintDisplay] dispose: START');
    _qrAnimationController.dispose();
    super.dispose();
    debugPrint('[KeyFingerprintDisplay] dispose: END');
  }

  String get _formattedFingerprint {
    debugPrint('[KeyFingerprintDisplay] _formattedFingerprint: Formatting fingerprint');
    final clean = widget.fingerprint.replaceAll(RegExp(r'[^a-fA-F0-9]'), '');
    if (clean.length < 16) return clean.toUpperCase();
    
    final groups = <String>[];
    for (var i = 0; i < clean.length && i < 16; i += 4) {
      final end = (i + 4).clamp(0, clean.length);
      groups.add(clean.substring(i, end).toUpperCase());
    }
    return groups.join('-');
  }

  void _toggleQr() {
    debugPrint('[KeyFingerprintDisplay] _toggleQr: Toggling QR display - current: $_showQr');
    setState(() {
      _showQr = !_showQr;
      if (_showQr) {
        _qrAnimationController.forward();
        debugPrint('[KeyFingerprintDisplay] _toggleQr: QR shown, animation forward');
      } else {
        _qrAnimationController.reverse();
        debugPrint('[KeyFingerprintDisplay] _toggleQr: QR hidden, animation reverse');
      }
    });
  }

  Future<void> _copyToClipboard() async {
    debugPrint('[KeyFingerprintDisplay] _copyToClipboard: Copying to clipboard');
    await Clipboard.setData(ClipboardData(text: widget.fingerprint));
    debugPrint('[KeyFingerprintDisplay] _copyToClipboard: Copied fingerprint to clipboard');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Fingerprint copied to clipboard'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _showVerifyDialog() {
    debugPrint('[KeyFingerprintDisplay] _showVerifyDialog: Showing verify dialog');
    showDialog(
      context: context,
      builder: (context) => _FingerprintVerifyDialog(
        fingerprint: _formattedFingerprint,
        onVerify: widget.onVerify,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[KeyFingerprintDisplay] build: Building - compact: ${widget.compact}');
    final colors = AppColors.of(context);

    if (widget.compact) {
      debugPrint('[KeyFingerprintDisplay] build: Using compact view');
      return _buildCompactView(colors);
    }

    return Semantics(
      label: 'Key fingerprint: ${_formattedFingerprint.replaceAll('-', ' ')}',
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.label != null) ...[
              Text(
                widget.label!,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: colors.secondaryText,
                ),
              ),
              const SizedBox(height: 12),
            ],
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: colors.inputBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.fingerprint, size: 20, color: colors.accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SelectableText(
                      _formattedFingerprint,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colors.primaryText,
                        letterSpacing: 1,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  if (widget.showCopyButton)
                    IconButton(
                      icon: Icon(Icons.copy, size: 20, color: colors.secondaryText),
                      onPressed: _copyToClipboard,
                      tooltip: 'Copy fingerprint',
                    ),
                ],
              ),
            ),
            if (widget.showQrCode || widget.showVerifyButton) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (widget.showQrCode)
                    Expanded(
                      child: _ActionChip(
                        icon: Icons.qr_code,
                        label: _showQr ? 'Hide QR' : 'Show QR',
                        onTap: _toggleQr,
                        colors: colors,
                      ),
                    ),
                  if (widget.showQrCode && widget.showVerifyButton)
                    const SizedBox(width: 8),
                  if (widget.showVerifyButton)
                    Expanded(
                      child: _ActionChip(
                        icon: Icons.verified_user,
                        label: 'Verify',
                        onTap: widget.onVerify ?? _showVerifyDialog,
                        colors: colors,
                        isAccent: true,
                      ),
                    ),
                ],
              ),
            ],
                if (widget.showQrCode)
              SizeTransition(
                sizeFactor: _qrAnimation,
                child: FadeTransition(
                  opacity: _qrAnimation,
                  child: Container(
                    margin: const EdgeInsets.only(top: 16),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Container(
                        width: 200,
                        height: 200,
                        color: Colors.white,
                        child: Center(
                          child: QrImageView(
                            data: widget.fingerprint,
                            version: QrVersions.auto,
                            size: 180,
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                            errorCorrectionLevel: QrErrorCorrectLevel.M,
                          ),
                        ),
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

  Widget _buildCompactView(AppColors colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.inputBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fingerprint, size: 16, color: colors.secondaryText),
          const SizedBox(width: 8),
          Text(
            _formattedFingerprint,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: colors.primaryText,
              letterSpacing: 0.5,
            ),
          ),
          if (widget.showCopyButton) ...[
            const SizedBox(width: 8),
            InkWell(
              onTap: _copyToClipboard,
              child: Icon(Icons.copy, size: 14, color: colors.secondaryText),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final AppColors colors;
  final bool isAccent;

  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.colors,
    this.isAccent = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          color: isAccent
              ? colors.accent.withValues(alpha: 0.1)
              : colors.inputBg,
          borderRadius: BorderRadius.circular(8),
          border: isAccent
              ? Border.all(color: colors.accent.withValues(alpha: 0.3))
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: isAccent ? colors.accent : colors.secondaryText,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isAccent ? colors.accent : colors.primaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FingerprintVerifyDialog extends StatefulWidget {
  final String fingerprint;
  final VoidCallback? onVerify;

  const _FingerprintVerifyDialog({
    required this.fingerprint,
    this.onVerify,
  });

  @override
  State<_FingerprintVerifyDialog> createState() => _FingerprintVerifyDialogState();
}

class _FingerprintVerifyDialogState extends State<_FingerprintVerifyDialog> {
  final _controller = TextEditingController();
  bool? _isMatch;
  bool _showScanner = false;

  void _checkMatch() {
    debugPrint('[FingerprintVerifyDialog] _checkMatch: Checking fingerprint match');
    final input = _controller.text.replaceAll(RegExp(r'[^a-fA-F0-9]'), '');
    final fingerprint = widget.fingerprint.replaceAll(RegExp(r'[^a-fA-F0-9]'), '');
    setState(() {
      _isMatch = input.toUpperCase() == fingerprint.toUpperCase();
    });
    debugPrint('[FingerprintVerifyDialog] _checkMatch: Match result: $_isMatch');
    
    if (_isMatch == true && widget.onVerify != null) {
      debugPrint('[FingerprintVerifyDialog] _checkMatch: Verification successful');
      widget.onVerify!();
    }
  }

  void _onQRScanned(String? scannedData) {
    debugPrint('[FingerprintVerifyDialog] _onQRScanned: QR scanned: $scannedData');
    if (scannedData != null) {
      _controller.text = scannedData;
      _checkMatch();
    }
    setState(() {
      _showScanner = false;
    });
  }

  @override
  void dispose() {
    debugPrint('[FingerprintVerifyDialog] dispose: START');
    _controller.dispose();
    super.dispose();
    debugPrint('[FingerprintVerifyDialog] dispose: END');
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[FingerprintVerifyDialog] build: Building - isMatch: $_isMatch');
    final colors = AppColors.of(context);

    return AlertDialog(
      backgroundColor: colors.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        'Verify Fingerprint',
        style: TextStyle(color: colors.primaryText),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Compare fingerprints with your contact to verify their identity.',
            style: TextStyle(color: colors.secondaryText, fontSize: 14),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.inputBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.fingerprint, size: 18, color: colors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.fingerprint,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colors.primaryText,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_showScanner) ...[
            Container(
              height: 250,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: MobileScanner(
                  onDetect: (capture) {
                    final barcodes = capture.barcodes;
                    if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                      _onQRScanned(barcodes.first.rawValue);
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => setState(() => _showScanner = false),
              icon: const Icon(Icons.keyboard),
              label: const Text('Enter manually instead'),
              style: TextButton.styleFrom(foregroundColor: colors.accent),
            ),
          ] else ...[
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: 'Enter contact\'s fingerprint',
                hintStyle: TextStyle(color: colors.hintText),
                filled: true,
                fillColor: colors.inputBg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: _isMatch != null
                    ? Icon(
                        _isMatch! ? Icons.check_circle : Icons.error,
                        color: _isMatch! ? Colors.green : Colors.red,
                      )
                    : null,
              ),
              style: TextStyle(color: colors.primaryText),
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () => setState(() => _showScanner = true),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR Code'),
              style: TextButton.styleFrom(foregroundColor: colors.accent),
            ),
          ],
          if (_isMatch == true) ...[
            const SizedBox(height: 8),
            Text(
              'Fingerprints match! Identity verified.',
              style: TextStyle(color: Colors.green, fontSize: 13),
            ),
          ] else if (_isMatch == false) ...[
            const SizedBox(height: 8),
            Text(
              'Fingerprints do not match. Please double-check.',
              style: TextStyle(color: Colors.red, fontSize: 13),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel', style: TextStyle(color: colors.accent)),
        ),
        TextButton(
          onPressed: _checkMatch,
          child: Text(
            'Verify',
            style: TextStyle(
              color: _isMatch == true ? Colors.green : colors.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// Displays security warnings in a dismissible banner
/// 
/// Features:
/// - Dismissible
/// - Shows action button (e.g., "Revalidate Keys")
/// - Different colors for warning vs critical
class SecurityWarningBanner extends StatefulWidget {
  final String message;
  final SecurityTrustLevel severity;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;
  final bool dismissible;

  const SecurityWarningBanner({
    super.key,
    required this.message,
    this.severity = SecurityTrustLevel.warning,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
    this.dismissible = true,
  });

  @override
  State<SecurityWarningBanner> createState() => _SecurityWarningBannerState();
}

class _SecurityWarningBannerState extends State<SecurityWarningBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    debugPrint('[SecurityWarningBanner] initState: START - severity: ${widget.severity}');
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));
    _fadeAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));
    _controller.forward();
    debugPrint('[SecurityWarningBanner] initState: END - animation started');
  }

  @override
  void dispose() {
    debugPrint('[SecurityWarningBanner] dispose: START');
    _controller.dispose();
    super.dispose();
    debugPrint('[SecurityWarningBanner] dispose: END');
  }

  void _dismiss() {
    debugPrint('[SecurityWarningBanner] _dismiss: User dismissed banner');
    _controller.reverse().then((_) {
      widget.onDismiss?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[SecurityWarningBanner] build: Building - message: "${widget.message}", severity: ${widget.severity}');
    final colors = AppColors.of(context);

    return Semantics(
      label: 'Security warning: ${widget.message}',
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: SlideTransition(
          position: _slideAnimation,
          child: Material(
            elevation: 4,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: _getBackgroundColor(colors),
                border: Border(
                  bottom: BorderSide(color: _getBorderColor()),
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    Icon(
                      _getIcon(),
                      size: 20,
                      color: _getIconColor(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.message,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: _getTextColor(colors),
                            ),
                          ),
                          if (widget.actionLabel != null) ...[
                            const SizedBox(height: 4),
                            GestureDetector(
                              onTap: () {
                                debugPrint('[SecurityWarningBanner] onAction: User tapped action - ${widget.actionLabel}');
                                widget.onAction?.call();
                              },
                              child: Text(
                                widget.actionLabel!,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: _getActionColor(),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (widget.dismissible)
                      IconButton(
                        icon: Icon(Icons.close, size: 18, color: _getIconColor()),
                        onPressed: _dismiss,
                        tooltip: 'Dismiss',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _getBackgroundColor(AppColors colors) {
    switch (widget.severity) {
      case SecurityTrustLevel.good:
        return Colors.green.withValues(alpha: 0.1);
      case SecurityTrustLevel.warning:
        return Colors.orange.withValues(alpha: 0.1);
      case SecurityTrustLevel.critical:
        return Colors.red.withValues(alpha: 0.1);
    }
  }

  Color _getBorderColor() {
    switch (widget.severity) {
      case SecurityTrustLevel.good:
        return Colors.green.withValues(alpha: 0.3);
      case SecurityTrustLevel.warning:
        return Colors.orange.withValues(alpha: 0.3);
      case SecurityTrustLevel.critical:
        return Colors.red.withValues(alpha: 0.3);
    }
  }

  Color _getIconColor() {
    switch (widget.severity) {
      case SecurityTrustLevel.good:
        return Colors.green;
      case SecurityTrustLevel.warning:
        return Colors.orange;
      case SecurityTrustLevel.critical:
        return Colors.red;
    }
  }

  Color _getTextColor(AppColors colors) {
    switch (widget.severity) {
      case SecurityTrustLevel.good:
        return Colors.green.shade800;
      case SecurityTrustLevel.warning:
        return Colors.orange.shade800;
      case SecurityTrustLevel.critical:
        return Colors.red.shade800;
    }
  }

  Color _getActionColor() {
    switch (widget.severity) {
      case SecurityTrustLevel.good:
        return Colors.green;
      case SecurityTrustLevel.warning:
        return Colors.orange;
      case SecurityTrustLevel.critical:
        return Colors.red;
    }
  }

  IconData _getIcon() {
    switch (widget.severity) {
      case SecurityTrustLevel.good:
        return Icons.check_circle;
      case SecurityTrustLevel.warning:
        return Icons.warning_amber;
      case SecurityTrustLevel.critical:
        return Icons.error;
    }
  }
}

/// Small badge shown on message bubbles indicating security status
/// 
/// Features:
/// - Shows if message has HMAC verified
/// - Shows if message used secure sending
/// - Tooltip with security details
class MessageSecurityBadge extends StatelessWidget {
  final bool isHmacVerified;
  final bool isSecureSending;
  final bool isEncrypted;
  final DateTime? timestamp;
  final String? keyVersion;
  final bool compact;

  const MessageSecurityBadge({
    super.key,
    this.isHmacVerified = false,
    this.isSecureSending = false,
    this.isEncrypted = true,
    this.timestamp,
    this.keyVersion,
    this.compact = true,
  });

  @override
  Widget build(BuildContext context) {
    debugPrint('[MessageSecurityBadge] build: Building - isHmacVerified: $isHmacVerified, isSecureSending: $isSecureSending, isEncrypted: $isEncrypted');
    final colors = AppColors.of(context);
    final tooltipMessage = _buildTooltipMessage();

    return Tooltip(
      message: tooltipMessage,
      preferBelow: false,
      child: Semantics(
        label: tooltipMessage,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 4 : 6,
            vertical: compact ? 2 : 3,
          ),
          decoration: BoxDecoration(
            color: _getBackgroundColor(colors),
            borderRadius: BorderRadius.circular(compact ? 4 : 6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _getIcon(),
                size: compact ? 10 : 12,
                color: _getIconColor(),
              ),
              if (!compact && keyVersion != null) ...[
                const SizedBox(width: 4),
                Text(
                  keyVersion!,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: _getIconColor(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _buildTooltipMessage() {
    debugPrint('[MessageSecurityBadge] _buildTooltipMessage: Building tooltip');
    final parts = <String>[];
    
    if (isEncrypted) {
      parts.add('End-to-end encrypted');
    }
    if (isHmacVerified) {
      parts.add('HMAC verified');
    }
    if (isSecureSending) {
      parts.add('Secure sending');
    }
    if (keyVersion != null) {
      parts.add('Key version: $keyVersion');
    }
    if (timestamp != null) {
      parts.add('Sent: ${_formatTime(timestamp!)}');
    }
    
    final tooltip = parts.join('\n');
    debugPrint('[MessageSecurityBadge] _buildTooltipMessage: Generated tooltip: "$tooltip"');
    return tooltip;
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  IconData _getIcon() {
    debugPrint('[MessageSecurityBadge] _getIcon: Determining icon - isHmacVerified: $isHmacVerified, isSecureSending: $isSecureSending');
    if (isHmacVerified && isSecureSending) {
      return Icons.verified;
    } else if (isEncrypted) {
      return Icons.lock;
    } else {
      return Icons.lock_open;
    }
  }

  Color _getBackgroundColor(AppColors colors) {
    debugPrint('[MessageSecurityBadge] _getBackgroundColor: Determining background color');
    if (isHmacVerified && isSecureSending) {
      return Colors.green.withValues(alpha: 0.15);
    } else if (isEncrypted) {
      return colors.accent.withValues(alpha: 0.15);
    } else {
      return Colors.grey.withValues(alpha: 0.15);
    }
  }

  Color _getIconColor() {
    debugPrint('[MessageSecurityBadge] _getIconColor: Determining icon color');
    if (isHmacVerified && isSecureSending) {
      return Colors.green;
    } else if (isEncrypted) {
      return Colors.blue;
    } else {
      return Colors.grey;
    }
  }
}

/// Animated security indicator with pulse effect for critical states
class AnimatedSecurityIndicator extends StatefulWidget {
  final SecurityTrustLevel level;
  final double size;
  final bool pulse;

  const AnimatedSecurityIndicator({
    super.key,
    required this.level,
    this.size = 12,
    this.pulse = true,
  });

  @override
  State<AnimatedSecurityIndicator> createState() => _AnimatedSecurityIndicatorState();
}

class _AnimatedSecurityIndicatorState extends State<AnimatedSecurityIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    debugPrint('[AnimatedSecurityIndicator] initState: START - level: ${widget.level}, pulse: ${widget.pulse}');
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    
    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.3), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 1.3, end: 1.0), weight: 1),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));
    
    _opacityAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.6), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 0.6, end: 1.0), weight: 1),
    ]).animate(_controller);

    if (widget.pulse && widget.level == SecurityTrustLevel.critical) {
      debugPrint('[AnimatedSecurityIndicator] initState: Starting pulse animation for critical level');
      _controller.repeat();
    }
    debugPrint('[AnimatedSecurityIndicator] initState: END');
  }

  @override
  void didUpdateWidget(AnimatedSecurityIndicator oldWidget) {
    debugPrint('[AnimatedSecurityIndicator] didUpdateWidget: START - level changed from ${oldWidget.level} to ${widget.level}');
    super.didUpdateWidget(oldWidget);
    if (widget.level == SecurityTrustLevel.critical && widget.pulse) {
      if (!_controller.isAnimating) {
        debugPrint('[AnimatedSecurityIndicator] didUpdateWidget: Starting pulse animation');
        _controller.repeat();
      }
    } else {
      debugPrint('[AnimatedSecurityIndicator] didUpdateWidget: Stopping animation');
      _controller.stop();
      _controller.reset();
    }
    debugPrint('[AnimatedSecurityIndicator] didUpdateWidget: END');
  }

  @override
  void dispose() {
    debugPrint('[AnimatedSecurityIndicator] dispose: START');
    _controller.dispose();
    super.dispose();
    debugPrint('[AnimatedSecurityIndicator] dispose: END');
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[AnimatedSecurityIndicator] build: Building - level: ${widget.level}, size: ${widget.size}');
    final color = _getColor();
    
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(
          scale: widget.pulse && widget.level == SecurityTrustLevel.critical
              ? _scaleAnimation.value
              : 1.0,
          child: Opacity(
            opacity: widget.pulse && widget.level == SecurityTrustLevel.critical
                ? _opacityAnimation.value
                : 1.0,
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.4),
                    blurRadius: widget.size * 0.3,
                    spreadRadius: widget.size * 0.1,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Color _getColor() {
    debugPrint('[AnimatedSecurityIndicator] _getColor: Getting color for level: ${widget.level}');
    switch (widget.level) {
      case SecurityTrustLevel.good:
        return Colors.green;
      case SecurityTrustLevel.warning:
        return Colors.orange;
      case SecurityTrustLevel.critical:
        return Colors.red;
    }
  }
}

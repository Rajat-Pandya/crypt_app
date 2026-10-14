import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import 'security_indicators.dart';

/// A bottom sheet that displays comprehensive security details
/// 
/// Features:
/// - Current trust score with breakdown
/// - Session info (created, last activity)
/// - Key versions
/// - Security issues list with explanations
/// - Actions: Revalidate, Rotate Keys, Clear Cache
class SecurityDetailsSheet extends StatelessWidget {
  final SecurityStatusData status;
  final VoidCallback? onRevalidate;
  final VoidCallback? onRotateKeys;
  final VoidCallback? onClearCache;
  final String? currentUserId;
  final String? receiverId;

  const SecurityDetailsSheet({
    super.key,
    required this.status,
    this.onRevalidate,
    this.onRotateKeys,
    this.onClearCache,
    this.currentUserId,
    this.receiverId,
  });

  @override
  Widget build(BuildContext context) {
    debugPrint('[SecurityDetailsSheet] build: Building - trustScore: ${status.trustScore}, issues: ${status.issues.length}');
    final colors = AppColors.of(context);

    return Container(
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHandle(colors),
            Flexible(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildHeader(colors),
                          const SizedBox(height: 24),
                          _buildTrustScoreSection(colors),
                          const SizedBox(height: 24),
                          _buildSessionInfoSection(context, colors),
                          const SizedBox(height: 24),
                          _buildKeyInfoSection(context, colors),
                          if (status.issues.isNotEmpty) ...[
                            const SizedBox(height: 24),
                            _buildIssuesSection(colors),
                          ],
                          const SizedBox(height: 24),
                          _buildActionsSection(colors),
                          const SizedBox(height: 20),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHandle(AppColors colors) {
    debugPrint('[SecurityDetailsSheet] _buildHandle: Building handle');
    return Container(
      margin: const EdgeInsets.only(top: 12, bottom: 8),
      width: 40,
      height: 4,
      decoration: BoxDecoration(
        color: colors.borderColor,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _buildHeader(AppColors colors) {
    debugPrint('[SecurityDetailsSheet] _buildHeader: Building header');
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            Icons.security,
            size: 24,
            color: colors.accent,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Security Details',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: colors.primaryText,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Encryption & Verification Status',
                style: TextStyle(
                  fontSize: 14,
                  color: colors.secondaryText,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTrustScoreSection(AppColors colors) {
    debugPrint('[SecurityDetailsSheet] _buildTrustScoreSection: Building trust score section - score: ${status.trustScore}');
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _getTrustScoreBackgroundColor(colors),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _getTrustScoreBorderColor().withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AnimatedSecurityIndicator(
                level: status.trustLevel,
                size: 16,
              ),
              const SizedBox(width: 12),
              Text(
                'Trust Score',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.primaryText,
                ),
              ),
              const Spacer(),
              Text(
                '${status.trustScore}%',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: _getTrustScoreColor(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildTrustScoreBar(colors),
          const SizedBox(height: 12),
          Text(
            _getTrustScoreDescription(),
            style: TextStyle(
              fontSize: 13,
              color: colors.secondaryText,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrustScoreBar(AppColors colors) {
    debugPrint('[SecurityDetailsSheet] _buildTrustScoreBar: Building trust score bar');
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
            Container(
              height: 8,
              width: constraints.maxWidth * (status.trustScore / 100),
              decoration: BoxDecoration(
                color: _getTrustScoreColor(),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSessionInfoSection(BuildContext context, AppColors colors) {
    debugPrint('[SecurityDetailsSheet] _buildSessionInfoSection: Building session info section');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Session Information',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: colors.primaryText,
          ),
        ),
        const SizedBox(height: 12),
        _buildInfoCard(
          colors: colors,
          children: [
            if (status.sessionCreated != null)
              _buildInfoRow(
                context,
                colors: colors,
                icon: Icons.play_circle_outline,
                label: 'Session Started',
                value: _formatDateTime(status.sessionCreated!),
              ),
            if (status.lastActivity != null) ...[
              if (status.sessionCreated != null)
                Divider(height: 16, color: colors.divider),
              _buildInfoRow(
                context,
                colors: colors,
                icon: Icons.access_time,
                label: 'Last Activity',
                value: _formatDateTime(status.lastActivity!),
              ),
            ],
            if (currentUserId != null) ...[
              if (status.sessionCreated != null || status.lastActivity != null)
                Divider(height: 16, color: colors.divider),
              _buildInfoRow(
                context,
                colors: colors,
                icon: Icons.person_outline,
                label: 'User ID',
                value: _truncateId(currentUserId!),
                copyable: true,
                valueToCopy: currentUserId,
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildKeyInfoSection(BuildContext context, AppColors colors) {
    debugPrint('[SecurityDetailsSheet] _buildKeyInfoSection: Building key info section');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Encryption Keys',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: colors.primaryText,
          ),
        ),
        const SizedBox(height: 12),
        _buildInfoCard(
          colors: colors,
          children: [
            _buildInfoRow(
              context,
              colors: colors,
              icon: Icons.vpn_key,
              label: 'Key Version',
              value: status.keyVersion ?? 'Legacy',
            ),
            Divider(height: 16, color: colors.divider),
            _buildInfoRow(
              context,
              colors: colors,
              icon: Icons.verified_user,
              label: 'HMAC Status',
              value: status.isHmacVerified ? 'Verified' : 'Not Verified',
              valueColor: status.isHmacVerified ? Colors.green : Colors.orange,
            ),
            Divider(height: 16, color: colors.divider),
            _buildInfoRow(
              context,
              colors: colors,
              icon: Icons.security,
              label: 'Secure Sending',
              value: status.isSecureSendingEnabled ? 'Enabled' : 'Standard',
              valueColor: status.isSecureSendingEnabled ? Colors.green : colors.secondaryText,
            ),
            if (status.fingerprint != null) ...[
              Divider(height: 16, color: colors.divider),
              _buildFingerprintRow(context, colors),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildFingerprintRow(BuildContext context, AppColors colors) {
    debugPrint('[SecurityDetailsSheet] _buildFingerprintRow: Building fingerprint row');
    final clean = status.fingerprint!.replaceAll(RegExp(r'[^a-fA-F0-9]'), '');
    final formatted = clean.length >= 16
        ? '${clean.substring(0, 4).toUpperCase()}-${clean.substring(4, 8).toUpperCase()}-${clean.substring(8, 12).toUpperCase()}-${clean.substring(12, 16).toUpperCase()}'
        : clean.toUpperCase();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.fingerprint, size: 18, color: colors.secondaryText),
            const SizedBox(width: 12),
            Text(
              'Fingerprint',
              style: TextStyle(
                fontSize: 14,
                color: colors.secondaryText,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: colors.inputBg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  formatted,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.primaryText,
                    letterSpacing: 0.5,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.copy, size: 18, color: colors.secondaryText),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: status.fingerprint!));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Fingerprint copied'),
                        behavior: SnackBarBehavior.floating,
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                },
                tooltip: 'Copy fingerprint',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildIssuesSection(AppColors colors) {
    debugPrint('[SecurityDetailsSheet] _buildIssuesSection: Building issues section - count: ${status.issues.length}');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.warning_amber,
              size: 20,
              color: Colors.orange,
            ),
            const SizedBox(width: 8),
            Text(
              'Security Issues',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colors.primaryText,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${status.issues.length}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.orange,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildInfoCard(
          colors: colors,
          children: status.issues.map((issue) {
            return _buildIssueItem(colors, issue);
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildIssueItem(AppColors colors, SecurityIssue issue) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: _getIssueColor(issue.severity).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              _getIssueIcon(issue.severity),
              size: 14,
              color: _getIssueColor(issue.severity),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  issue.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.primaryText,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  issue.description,
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.secondaryText,
                    height: 1.4,
                  ),
                ),
                if (issue.timestamp != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Detected: ${_formatDateTime(issue.timestamp!)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.hintText,
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

  Widget _buildActionsSection(AppColors colors) {
    debugPrint('[SecurityDetailsSheet] _buildActionsSection: Building actions section');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Actions',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: colors.primaryText,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildActionButton(
                colors: colors,
                icon: Icons.refresh,
                label: 'Revalidate',
                onTap: () {
                  debugPrint('[SecurityDetailsSheet] _onRevalidate: User tapped revalidate button');
                  onRevalidate?.call();
                },
                isPrimary: true,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildActionButton(
                colors: colors,
                icon: Icons.rotate_right,
                label: 'Rotate Keys',
                onTap: () {
                  debugPrint('[SecurityDetailsSheet] _onRotateKeys: User tapped rotate keys button');
                  onRotateKeys?.call();
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildActionButton(
                colors: colors,
                icon: Icons.cleaning_services,
                label: 'Clear Cache',
                onTap: () {
                  debugPrint('[SecurityDetailsSheet] _onClearCache: User tapped clear cache button');
                  onClearCache?.call();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInfoCard({
    required AppColors colors,
    required List<Widget> children,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.inputBg.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _buildInfoRow(
    BuildContext context, {
    required AppColors colors,
    required IconData icon,
    required String label,
    required String value,
    Color? valueColor,
    bool copyable = false,
    String? valueToCopy,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18, color: colors.secondaryText),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: colors.secondaryText,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: valueColor ?? colors.primaryText,
                ),
              ),
            ],
          ),
        ),
        if (copyable)
          IconButton(
            icon: Icon(Icons.copy, size: 18, color: colors.secondaryText),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: valueToCopy ?? value));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied to clipboard'),
                    behavior: SnackBarBehavior.floating,
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
            tooltip: 'Copy',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
      ],
    );
  }

  Widget _buildActionButton({
    required AppColors colors,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool isPrimary = false,
  }) {
    debugPrint('[SecurityDetailsSheet] _buildActionButton: Building button - label: "$label", isPrimary: $isPrimary');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: isPrimary
              ? colors.accent.withValues(alpha: 0.1)
              : colors.inputBg,
          borderRadius: BorderRadius.circular(12),
          border: isPrimary
              ? Border.all(color: colors.accent.withValues(alpha: 0.3))
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 24,
              color: isPrimary ? colors.accent : colors.secondaryText,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isPrimary ? colors.accent : colors.primaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    debugPrint('[SecurityDetailsSheet] _formatDateTime: Formatting $dateTime');
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inDays == 0) {
      if (diff.inHours == 0) {
        if (diff.inMinutes == 0) {
          return 'Just now';
        }
        return '${diff.inMinutes}m ago';
      }
      return '${diff.inHours}h ago';
    } else if (diff.inDays == 1) {
      return 'Yesterday, ${_formatTime(dateTime)}';
    } else if (diff.inDays < 7) {
      return '${_getDayName(dateTime.weekday)}, ${_formatTime(dateTime)}';
    } else {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year} ${_formatTime(dateTime)}';
    }
  }

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _getDayName(int day) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[day - 1];
  }

  String _truncateId(String id) {
    if (id.length <= 16) return id;
    return '${id.substring(0, 8)}...${id.substring(id.length - 8)}';
  }

  Color _getTrustScoreColor() {
    debugPrint('[SecurityDetailsSheet] _getTrustScoreColor: Getting color for trustLevel: ${status.trustLevel}');
    switch (status.trustLevel) {
      case SecurityTrustLevel.good:
        return Colors.green;
      case SecurityTrustLevel.warning:
        return Colors.orange;
      case SecurityTrustLevel.critical:
        return Colors.red;
    }
  }

  Color _getTrustScoreBackgroundColor(AppColors colors) {
    switch (status.trustLevel) {
      case SecurityTrustLevel.good:
        return Colors.green.withValues(alpha: 0.05);
      case SecurityTrustLevel.warning:
        return Colors.orange.withValues(alpha: 0.05);
      case SecurityTrustLevel.critical:
        return Colors.red.withValues(alpha: 0.05);
    }
  }

  Color _getTrustScoreBorderColor() {
    switch (status.trustLevel) {
      case SecurityTrustLevel.good:
        return Colors.green;
      case SecurityTrustLevel.warning:
        return Colors.orange;
      case SecurityTrustLevel.critical:
        return Colors.red;
    }
  }

  String _getTrustScoreDescription() {
    switch (status.trustLevel) {
      case SecurityTrustLevel.good:
        return 'Your security is at a good level. All encryption mechanisms are functioning correctly.';
      case SecurityTrustLevel.warning:
        return 'Some security features may need attention. Review the issues below for details.';
      case SecurityTrustLevel.critical:
        return 'Critical security issues detected. Immediate action recommended to secure your communications.';
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
}

/// Shows the security details sheet as a modal bottom sheet
void showSecurityDetailsSheet(
  BuildContext context, {
  required SecurityStatusData status,
  VoidCallback? onRevalidate,
  VoidCallback? onRotateKeys,
  VoidCallback? onClearCache,
  String? currentUserId,
  String? receiverId,
}) {
  debugPrint('[SecurityDetailsSheet] showSecurityDetailsSheet: Showing sheet - trustScore: ${status.trustScore}, issues: ${status.issues.length}');
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return SecurityDetailsSheet(
          status: status,
          onRevalidate: onRevalidate,
          onRotateKeys: onRotateKeys,
          onClearCache: onClearCache,
          currentUserId: currentUserId,
          receiverId: receiverId,
        );
      },
    ),
  );
}

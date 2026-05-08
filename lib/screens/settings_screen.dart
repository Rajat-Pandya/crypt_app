import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  static Future<bool> isSoundEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool("sound") ?? true;
  }

  static Future<void> vibrateIfEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool("vibration") ?? true;
    if (!enabled) return;
    HapticFeedback.mediumImpact();
  }

  static Future<bool> isMessagePreviewEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool("messagePreview") ?? true;
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

  @override
  void initState() {
    super.initState();
    debugPrint('[Settings] initState: START');
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    debugPrint('[Settings] _loadSettings: START');
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _isDarkMode = prefs.getBool("darkMode") ?? false;
      _notificationsEnabled = prefs.getBool("notifications") ?? true;
      _messagePreview = prefs.getBool("messagePreview") ?? true;
      _soundEnabled = prefs.getBool("sound") ?? true;
      _vibrationEnabled = prefs.getBool("vibration") ?? true;
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
      if (mounted) _showSnack("Could not open link", Colors.red);
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

    final darkMode = prefs.getBool("darkMode") ?? false;
    final notifications = prefs.getBool("notifications") ?? true;
    final messagePreview = prefs.getBool("messagePreview") ?? true;
    final sound = prefs.getBool("sound") ?? true;
    final vibration = prefs.getBool("vibration") ?? true;

    await prefs.clear();

    await prefs.setBool("darkMode", darkMode);
    await prefs.setBool("notifications", notifications);
    await prefs.setBool("messagePreview", messagePreview);
    await prefs.setBool("sound", sound);
    await prefs.setBool("vibration", vibration);

    themeNotifier.value = darkMode ? ThemeMode.dark : ThemeMode.light;
    debugPrint('[Settings] _clearCacheOnly: COMPLETE');
  }

  void _showClearCacheDialog(AppColors colors) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text("Clear Cache", style: TextStyle(color: colors.primaryText)),
        content: Text(
          "This will clear your local message cache. "
          "Your messages are safe on the server. "
          "Your settings and preferences will be kept.",
          style: TextStyle(color: colors.secondaryText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("Cancel", style: TextStyle(color: colors.accent)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _clearCacheOnly();
              if (mounted) {
                _showSnack("Cache cleared successfully", Colors.green);
                _loadSettings();
              }
            },
            child: const Text("Clear", style: TextStyle(color: Colors.red)),
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
          "Settings",
          style: TextStyle(
            color: colors.primaryText,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: colors.accent))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const SizedBox(height: 8),
                _buildSectionHeader(
                  icon: Icons.palette_outlined,
                  title: "Appearance",
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
                      title: "Dark Mode",
                      subtitle: "Switch to dark theme",
                      value: _isDarkMode,
                      colors: colors,
                      onChanged: (v) {
                        _toggle("darkMode", v, (val) => _isDarkMode = val);
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
                  title: "Notifications",
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
                      title: "Push Notifications",
                      subtitle: "Receive message alerts",
                      value: _notificationsEnabled,
                      colors: colors,
                      onChanged: (v) {
                        _toggle(
                          "notifications",
                          v,
                          (val) => _notificationsEnabled = val,
                        );
                      },
                    ),
                    _buildDivider(colors),
                    _buildSwitchTile(
                      icon: Icons.message_outlined,
                      iconColor: const Color(0xFF8B5CF6),
                      title: "Sender Preview",
                      subtitle: "Show sender name in notifications",
                      value: _messagePreview,
                      colors: colors,
                      onChanged: _notificationsEnabled
                          ? (v) => _toggle(
                              "messagePreview",
                              v,
                              (val) => _messagePreview = val,
                            )
                          : null,
                    ),
                    _buildDivider(colors),
                    _buildSwitchTile(
                      icon: Icons.volume_up_outlined,
                      iconColor: const Color(0xFF22C55E),
                      title: "Sound",
                      subtitle: "Play sound for new messages",
                      value: _soundEnabled,
                      colors: colors,
                      onChanged: _notificationsEnabled
                          ? (v) => _toggle(
                              "sound",
                              v,
                              (val) => _soundEnabled = val,
                            )
                          : null,
                    ),
                    _buildDivider(colors),
                    _buildSwitchTile(
                      icon: Icons.vibration,
                      iconColor: const Color(0xFFF59E0B),
                      title: "Vibration",
                      subtitle: "Vibrate for new messages",
                      value: _vibrationEnabled,
                      colors: colors,
                      onChanged: _notificationsEnabled
                          ? (v) => _toggle(
                              "vibration",
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
                  title: "Privacy & Security",
                  color: const Color(0xFF22C55E),
                  colors: colors,
                ),
                const SizedBox(height: 10),
                _buildSettingsCard(
                  colors: colors,
                  children: [
                    _buildNavTile(
                      icon: Icons.lock_outline,
                      iconColor: const Color(0xFF22C55E),
                      title: "End-to-End Encryption",
                      subtitle: "All messages are encrypted",
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
                          "Active",
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
                    _buildNavTile(
                      icon: Icons.delete_outline,
                      iconColor: Colors.red,
                      title: "Clear All Chats",
                      subtitle: "Delete all local message cache",
                      colors: colors,
                      onTap: () => _showClearCacheDialog(colors),
                      isLast: true,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildSectionHeader(
                  icon: Icons.info_outline,
                  title: "About",
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
                      title: "Privacy Policy",
                      subtitle: "How we handle your data",
                      colors: colors,
                      onTap: () => _launchUrl("https://yourapp.com/privacy"),
                    ),
                    _buildDivider(colors),
                    _buildNavTile(
                      icon: Icons.description_outlined,
                      iconColor: const Color(0xFF6366F1),
                      title: "Terms of Service",
                      subtitle: "Our terms and conditions",
                      colors: colors,
                      onTap: () => _launchUrl("https://yourapp.com/terms"),
                    ),
                    _buildDivider(colors),
                    _buildNavTile(
                      icon: Icons.info_outline,
                      iconColor: colors.secondaryText,
                      title: "App Version",
                      subtitle: "1.0.0",
                      colors: colors,
                      onTap: null,
                      isLast: true,
                    ),
                  ],
                ),
                const SizedBox(height: 40),
              ],
            ),
    );
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
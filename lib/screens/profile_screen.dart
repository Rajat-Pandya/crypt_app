import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/profile_photo_service.dart';
import '../utils/avatar_utils.dart';
import '../utils/input_validator.dart';
import '../main.dart';

class ProfileScreen extends StatefulWidget {
  final String? userId;

  const ProfileScreen({super.key, this.userId});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final currentUser = FirebaseAuth.instance.currentUser!;
  final _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLoading = true;
  bool _isSaving = false;
  String _currentName = '';
  String _displayEmail = '';

  String get displayUserId => widget.userId ?? currentUser.uid;

  bool get isOwnProfile =>
      widget.userId == null || widget.userId == currentUser.uid;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  // ── Firestore ──────────────────────────────────────────────

  Future<void> _loadProfile() async {
    debugPrint('[Profile] _loadProfile: START, userId=$displayUserId');
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(displayUserId)
          .get();

      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        final name = data['name'] as String? ?? '';

        // ── Fix 3: load email once here instead of streaming ──
        // Email does not change during a profile view session.
        // A one-time get() avoids an unnecessary live listener.
        //
        // ── Fix — privacy: only show email on own profile ─────
        // Other users' email addresses are stored in Firestore
        // but should not be visible to contacts.
        // Own profile shows email for account management.
        // Other profiles show nothing — name is sufficient.
        // Fix: Use Firestore email if available, otherwise fall back to Firebase Auth
        final firestoreEmail = data['email'] as String?;
        final authEmail = FirebaseAuth.instance.currentUser?.email ?? '';
        final email = isOwnProfile 
            ? (firestoreEmail?.isNotEmpty == true ? firestoreEmail! : authEmail) 
            : '';

        setState(() {
          _currentName = name;
          _displayEmail = email;
          _nameController.text = name;
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('[Profile] _loadProfile: ERROR ${e.runtimeType}');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveName() async {
    debugPrint('[Profile] _saveName: START');
    if (!_formKey.currentState!.validate()) return;

    final newName = _nameController.text.trim();

    if (newName == _currentName) {
      debugPrint('[Profile] _saveName: name unchanged, skipping');
      _showSnack('Name is already up to date', Colors.orange);
      return;
    }

    setState(() => _isSaving = true);
    debugPrint('[Profile] _saveName: saving newName=$newName');

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .set({'name': newName}, SetOptions(merge: true));

      setState(() {
        _currentName = newName;
        _isSaving = false;
      });

      _showSnack('Profile updated successfully!', Colors.green);
      debugPrint('[Profile] _saveName: SUCCESS');
    } catch (e) {
      debugPrint('[Profile] _saveName: ERROR ${e.runtimeType}');
      setState(() => _isSaving = false);
      _showSnack('Failed to save. Please try again.', Colors.red);
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

  // ── Build ──────────────────────────────────────────────────

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
          isOwnProfile ? 'My Profile' : 'Profile',
          style: TextStyle(
            color: colors.primaryText,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: colors.accent))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 20),

                    _buildAvatar(colors),

                    const SizedBox(height: 32),

                    if (isOwnProfile) ...[
                      _buildInfoCard(colors),
                      const SizedBox(height: 24),
                    ],

                    if (isOwnProfile)
                      _buildNameField(colors)
                    else
                      _buildReadOnlyName(colors),

                    const SizedBox(height: 24),

                    // ── Email — own profile only ───────────────
                    if (isOwnProfile) _buildEmailField(colors),

                    const SizedBox(height: 32),

                    if (isOwnProfile) _buildSaveButton(colors),

                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
    );
  }

  // ── Avatar ─────────────────────────────────────────────────

  Widget _buildAvatar(AppColors colors) {
    if (!isOwnProfile) {
      return _avatarCircle(_currentName, colors);
    }

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _nameController,
      builder: (context, value, _) {
        final displayName = value.text.trim().isEmpty
            ? _currentName
            : value.text.trim();

        return Stack(
          alignment: Alignment.bottomRight,
          children: [
            _avatarCircle(displayName, colors),
            GestureDetector(
              onTap: () => _onEditPhotoTapped(context),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: colors.cardBg,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 6,
                    ),
                  ],
                ),
                child: Icon(Icons.edit, size: 16, color: colors.accent),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Handle edit photo tap - show photo options
  void _onEditPhotoTapped(BuildContext context) {
    ProfilePhotoService.showPhotoOptions(
      context,
      onCamera: () => _uploadPhotoFromCamera(),
      onGallery: () => _uploadPhotoFromGallery(),
      onRemove: () => _removePhoto(),
    );
  }

  /// Upload photo from camera
  Future<void> _uploadPhotoFromCamera() async {
    final service = ProfilePhotoService();
    
    setState(() => _isLoading = true);
    
    try {
      // Pick image from camera
      final imageFile = await service.pickFromCamera();
      if (imageFile == null) {
        setState(() => _isLoading = false);
        return;
      }
      
      // Upload the photo
      final photoUrl = await service.uploadProfilePhoto(imageFile);
      
      setState(() => _isLoading = false);
      
      if (photoUrl != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile photo updated!')),
          );
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload photo: $e')),
        );
      }
    }
  }

  /// Upload photo from gallery
  Future<void> _uploadPhotoFromGallery() async {
    final service = ProfilePhotoService();
    
    setState(() => _isLoading = true);
    
    try {
      // Pick image from gallery
      final imageFile = await service.pickFromGallery();
      if (imageFile == null) {
        setState(() => _isLoading = false);
        return;
      }
      
      // Upload the photo
      final photoUrl = await service.uploadProfilePhoto(imageFile);
      
      setState(() => _isLoading = false);
      
      if (photoUrl != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile photo updated!')),
          );
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload photo: $e')),
        );
      }
    }
  }

  /// Remove profile photo
  Future<void> _removePhoto() async {
    // Show confirmation dialog
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Photo'),
        content: const Text('Are you sure you want to remove your profile photo?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    
    if (confirm == true) {
      setState(() => _isLoading = true);
      
      try {
        await ProfilePhotoService().removeProfilePhoto();
        setState(() => _isLoading = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile photo removed')),
          );
        }
      } catch (e) {
        setState(() => _isLoading = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to remove photo: $e')),
          );
        }
      }
    }
  }

  /// Shared avatar circle used for both own and other profiles.
  Widget _avatarCircle(String name, AppColors colors) {
    return Container(
      width: 110,
      height: 110,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFF3B82F6), Color(0xFF6366F1)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF3B82F6).withValues(alpha: 0.35),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Center(
        child: Text(
          getInitials(name),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 38,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
      ),
    );
  }

  // ── Info Card ──────────────────────────────────────────────

  Widget _buildInfoCard(AppColors colors) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.accent.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: colors.accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Your name is visible to everyone you chat with. '
              'Initials are generated automatically.',
              style: TextStyle(fontSize: 13, color: colors.secondaryText),
            ),
          ),
        ],
      ),
    );
  }

  // ── Name Field (editable) ──────────────────────────────────

  Widget _buildNameField(AppColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Display Name',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: colors.secondaryText,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _nameController,
          textCapitalization: TextCapitalization.words,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: colors.primaryText,
          ),
          decoration: InputDecoration(
            hintText: 'Enter your name',
            hintStyle: TextStyle(color: colors.hintText),
            prefixIcon: Icon(Icons.person_outline, color: colors.accent),
            filled: true,
            fillColor: colors.cardBg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: colors.borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: colors.borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: colors.accent, width: 2),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Colors.red),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Colors.red, width: 2),
            ),
          ),
          // ── Fix 1: use InputValidator.validateName() ───────
          // Previously: inline validator with 30-char limit
          // InputValidator.validateName() uses 50-char limit
          // Single source of truth — no inconsistency between screens
          validator: (value) => InputValidator.validateName(value),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  // ── Name Field (read-only for other users) ─────────────────

  Widget _buildReadOnlyName(AppColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Display Name',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: colors.secondaryText,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: colors.inputBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: colors.borderColor),
          ),
          child: Row(
            children: [
              Icon(Icons.person_outline, color: colors.secondaryText, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _currentName.isEmpty ? 'No name set' : _currentName,
                  style: TextStyle(
                    fontSize: 15,
                    color: colors.primaryText,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Email Field (own profile only, static) ─────────────────

  /// ── Fix 3: no longer a StreamBuilder ──────────────────────
  /// Email loaded once in _loadProfile() — no live listener needed.
  /// Email is only shown for isOwnProfile — other users' emails
  /// are a privacy concern and are not displayed.
  Widget _buildEmailField(AppColors colors) {
    final isVerified = currentUser.emailVerified;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Email',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: colors.secondaryText,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: colors.inputBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: colors.borderColor),
          ),
          child: Row(
            children: [
              Icon(Icons.email_outlined, color: colors.secondaryText, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _displayEmail.isEmpty ? 'No email' : _displayEmail,
                  style: TextStyle(fontSize: 15, color: colors.secondaryText),
                ),
              ),
              if (isVerified)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.green.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.verified, size: 12, color: Colors.green),
                      const SizedBox(width: 4),
                      Text(
                        'Verified',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.green.shade400,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Save Button ────────────────────────────────────────────

  Widget _buildSaveButton(AppColors colors) {
    final hasChanged =
        _nameController.text.trim() != _currentName &&
        _nameController.text.trim().isNotEmpty;

    // ── Fix 2: button functionally disabled when nothing changed
    // Previously: AnimatedOpacity faded it but onPressed still fired
    // Now: onPressed is null when !hasChanged — truly disabled
    return AnimatedOpacity(
      opacity: hasChanged ? 1.0 : 0.45,
      duration: const Duration(milliseconds: 200),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: (_isSaving || !hasChanged) ? null : _saveName,
          // ✅ null when saving OR when nothing changed
          icon: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.save_outlined),
          label: Text(
            _isSaving ? 'Saving...' : 'Save Changes',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: colors.accent,
            foregroundColor: Colors.white,
            disabledBackgroundColor: colors.accent.withValues(alpha: 0.6),
            disabledForegroundColor: Colors.white70,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            elevation: hasChanged ? 4 : 0,
            shadowColor: colors.accent.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../cache/cache_service.dart';

/// Service for handling profile photo upload and management.
/// 
/// Features:
/// - Image picker (camera/gallery)
/// - Compression (max 512x512, quality 75)
/// - Firebase Storage upload
/// - Firestore URL update
/// - Progress tracking
/// - Local caching
/// 
/// NOTE: Firebase Storage must be enabled in Firebase Console for uploads to work.
/// If you get 404 errors, check that:
/// 1. Firebase Storage is enabled in your project
/// 2. Storage rules allow authenticated uploads
/// 3. The storage bucket exists and is properly configured
class ProfilePhotoService {
  static final ProfilePhotoService _instance = ProfilePhotoService._internal();
  factory ProfilePhotoService() => _instance;
  ProfilePhotoService._internal();

  static final _storage = FirebaseStorage.instance;
  static final _firestore = FirebaseFirestore.instance;
  static final _auth = FirebaseAuth.instance;
  static final _picker = ImagePicker();

  // Upload progress controller
  final _progressController = StreamController<double>.broadcast();
  Stream<double> get uploadProgress => _progressController.stream;

  bool _isUploading = false;
  bool get isUploading => _isUploading;

  /// Show bottom sheet with photo options
  static void showPhotoOptions(BuildContext context, {
    required VoidCallback onCamera,
    required VoidCallback onGallery,
    required VoidCallback onRemove,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Camera'),
              onTap: () {
                Navigator.pop(context);
                onCamera();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Gallery'),
              onTap: () {
                Navigator.pop(context);
                onGallery();
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Remove photo', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                onRemove();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Pick image from camera
  Future<File?> pickFromCamera() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 75,
      );
      return picked != null ? File(picked.path) : null;
    } catch (e) {
      debugPrint('[ProfilePhotoService] Camera error: $e');
      return null;
    }
  }

  /// Pick image from gallery
  Future<File?> pickFromGallery() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 75,
      );
      return picked != null ? File(picked.path) : null;
    } catch (e) {
      debugPrint('[ProfilePhotoService] Gallery error: $e');
      return null;
    }
  }

  /// Compress image to max 512x512, quality 75
  Future<Uint8List?> compressImage(File imageFile) async {
    try {
      final result = await FlutterImageCompress.compressWithFile(
        imageFile.absolute.path,
        minWidth: 512,
        minHeight: 512,
        quality: 75,
        format: CompressFormat.jpeg,
      );
      return result;
    } catch (e) {
      debugPrint('[ProfilePhotoService] Compression error: $e');
      return null;
    }
  }

  /// Upload photo to Firebase Storage and update Firestore
  /// 
  /// Returns the download URL on success, null on failure.
  /// Common failure reasons:
  /// - User not logged in
  /// - Image compression failed
  /// - Firebase Storage not configured (404 error)
  /// - Permission denied (check Storage rules)
  /// - Network timeout
  Future<String?> uploadProfilePhoto(File imageFile) async {
    if (_isUploading) return null;
    
    final user = _auth.currentUser;
    if (user == null) {
      debugPrint('[ProfilePhotoService] No user logged in');
      return null;
    }

    _isUploading = true;
    _progressController.add(0.0);

    try {
      // Compress image
      _progressController.add(0.1);
      final compressed = await compressImage(imageFile);
      if (compressed == null) {
        throw Exception('Image compression failed');
      }

      // Upload to Firebase Storage
      _progressController.add(0.2);
      
      // Use a unique filename to avoid conflicts
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final storageRef = _storage.ref().child('users/${user.uid}/avatar_$timestamp.jpg');
      
      debugPrint('[ProfilePhotoService] Uploading to: ${storageRef.fullPath}');
      
      final uploadTask = storageRef.putData(
        compressed,
        SettableMetadata(
          contentType: 'image/jpeg',
          customMetadata: {
            'uploadedBy': user.uid,
            'uploadedAt': DateTime.now().toIso8601String(),
          },
        ),
      );

      // Track progress with error handling
      uploadTask.snapshotEvents.listen((snapshot) {
        try {
          if (snapshot.totalBytes > 0) {
            final progress = 0.2 + (snapshot.bytesTransferred / snapshot.totalBytes) * 0.6;
            _progressController.add(progress.clamp(0.2, 0.8));
          }
        } catch (e) {
          debugPrint('[ProfilePhotoService] Progress tracking error: $e');
        }
      }, onError: (e) {
        debugPrint('[ProfilePhotoService] Upload snapshot error: $e');
      });

      // Wait for upload with timeout
      final snapshot = await uploadTask.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          throw Exception('Upload timed out after 2 minutes');
        },
      );
      _progressController.add(0.9);

      // Get download URL
      final downloadUrl = await snapshot.ref.getDownloadURL();

      // Update Firestore
      await _firestore.collection('users').doc(user.uid).update({
        'photoUrl': downloadUrl,
        'photoUpdatedAt': FieldValue.serverTimestamp(),
      });

      // Update local cache
      final cached = await CacheService.getUser(user.uid);
      if (cached != null) {
        cached.photoUrl = downloadUrl;
        cached.syncedAt = DateTime.now();
        await CacheService.putUser(cached);
      }

      _progressController.add(1.0);
      debugPrint('[ProfilePhotoService] Upload successful: $downloadUrl');
      
      return downloadUrl;
    } on FirebaseException catch (e) {
      // Handle specific Firebase Storage errors
      debugPrint('[ProfilePhotoService] Firebase error: ${e.code} - ${e.message}');
      
      if (e.code == 'object-not-found') {
        debugPrint('[ProfilePhotoService] ⚠️ Storage bucket not configured or file not found');
        debugPrint('[ProfilePhotoService] Please ensure Firebase Storage is enabled in Firebase Console');
      } else if (e.code == 'unauthorized') {
        debugPrint('[ProfilePhotoService] ⚠️ No permission to upload. Check Storage rules');
      } else if (e.code == 'canceled') {
        debugPrint('[ProfilePhotoService] Upload was canceled by user');
      } else if (e.code == 'unknown') {
        debugPrint('[ProfilePhotoService] ⚠️ Network error or Storage not initialized');
      } else if (e.code == 'bucket-not-found') {
        debugPrint('[ProfilePhotoService] ⚠️ Storage bucket does not exist');
      }
      
      _progressController.add(0.0);
      return null;
    } catch (e) {
      debugPrint('[ProfilePhotoService] Upload error: $e');
      _progressController.add(0.0);
      return null;
    } finally {
      _isUploading = false;
      await Future.delayed(const Duration(milliseconds: 500));
      _progressController.add(0.0);
    }
  }

  /// Remove profile photo
  Future<void> removeProfilePhoto() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      // Delete from Storage (best effort - may not exist)
      final storageRef = _storage.ref().child('users/${user.uid}');
      await storageRef.listAll().then((result) async {
        for (var item in result.items) {
          if (item.name.startsWith('avatar_')) {
            await item.delete().catchError((e) {
              debugPrint('[ProfilePhotoService] Failed to delete ${item.name}: $e');
              return null;
            });
          }
        }
      });

      // Update Firestore
      await _firestore.collection('users').doc(user.uid).update({
        'photoUrl': FieldValue.delete(),
        'photoRemovedAt': FieldValue.serverTimestamp(),
      });

      // Update local cache
      final cached = await CacheService.getUser(user.uid);
      if (cached != null) {
        cached.photoUrl = null;
        cached.syncedAt = DateTime.now();
        await CacheService.putUser(cached);
      }

      debugPrint('[ProfilePhotoService] Photo removed');
    } catch (e) {
      debugPrint('[ProfilePhotoService] Remove error: $e');
    }
  }

  /// Get cached photo URL
  static Future<String?> getCachedPhotoUrl(String userId) async {
    final cached = await CacheService.getUser(userId);
    return cached?.photoUrl;
  }

  /// Dispose
  void dispose() {
    _progressController.close();
  }
}

import 'dart:convert';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/asymmetric/api.dart';

/// Manages multiple versions of encryption keys for decryption of historical messages.
/// 
/// Keys are stored with version identifiers to allow decryption of messages
/// encrypted with older key versions after key rotation.
class KeyVersionManager {
  static final KeyVersionManager _instance = KeyVersionManager._internal();
  factory KeyVersionManager() => _instance;
  KeyVersionManager._internal();

  static const _storage = FlutterSecureStorage();
  
  // In-memory cache of loaded keys by version
  final Map<String, RSAPrivateKey?> _keyVersionCache = {};
  
  // Track failed key loads to prevent spam
  final Set<String> _failedKeyVersions = {};
  
  // Current loaded key version
  String? _currentKeyVersion;
  
  // LRU cache for key versions (max 5 versions)
  final LinkedHashMap<String, RSAPrivateKey> _lruKeyCache = LinkedHashMap();
  static const int _maxCachedVersions = 5;

  // Logging helpers
  static void _logKey(String message) {
    assert(() {
      debugPrint('[KEY] $message');
      return true;
    }());
  }

  /// Get the current key version
  String? get currentKeyVersion => _currentKeyVersion;

  /// Set the current key version
  void setCurrentKeyVersion(String version) {
    _currentKeyVersion = version;
    _logKey('Current key version set: $version');
  }

  /// Load a private key by version.
  /// 
  /// First checks in-memory cache, then secure storage.
  /// Returns null if key not found or failed to load.
  Future<RSAPrivateKey?> loadPrivateKeyByVersion(String version) async {
    // Check if we already know this version failed
    if (_failedKeyVersions.contains(version)) {
      _logKey('Key version $version previously failed, skipping');
      return null;
    }

    // Check in-memory cache first
    if (_lruKeyCache.containsKey(version)) {
      _logKey('Key version $version found in LRU cache');
      // Move to end (most recently used)
      final key = _lruKeyCache.remove(version)!;
      _lruKeyCache[version] = key;
      return key;
    }

    // Check version cache
    if (_keyVersionCache.containsKey(version)) {
      _logKey('Key version $version found in version cache');
      return _keyVersionCache[version];
    }

    _logKey('Loading key version: $version');

    try {
      // Try to load from secure storage with version suffix
      final keyData = await _storage.read(key: 'private_key_$version');
      
      if (keyData == null) {
        // Try legacy key without version (for backwards compatibility)
        if (version == 'legacy' || version == 'v1') {
          final legacyKey = await _storage.read(key: 'private_key');
          if (legacyKey != null) {
            _logKey('Loaded legacy key for version: $version');
            final parsed = _parsePrivateKey(legacyKey);
            if (parsed != null) {
              _cacheKey(version, parsed);
              return parsed;
            }
          }
        }
        
        _logKey('Key version $version not found in storage');
        _failedKeyVersions.add(version);
        return null;
      }

      // Parse the key
      final parsed = _parsePrivateKey(keyData);
      if (parsed != null) {
        _cacheKey(version, parsed);
        _logKey('Key version $version loaded and cached');
        return parsed;
      } else {
        _logKey('Failed to parse key version $version');
        _failedKeyVersions.add(version);
        return null;
      }
    } catch (e) {
      _logKey('Error loading key version $version: ${e.runtimeType}');
      _failedKeyVersions.add(version);
      return null;
    }
  }

  /// Store a private key with version
  Future<void> storePrivateKeyWithVersion(
    String version,
    RSAPrivateKey privateKey,
    RSAPublicKey publicKey,
  ) async {
    try {
      final keyData = jsonEncode({
        'n': publicKey.modulus.toString(),
        'e': publicKey.exponent.toString(),
        'd': privateKey.privateExponent.toString(),
        'p': privateKey.p.toString(),
        'q': privateKey.q.toString(),
        'version': version,
      });

      await _storage.write(key: 'private_key_$version', value: keyData);
      
      // Also cache it
      _cacheKey(version, privateKey);
      
      // Update current version
      _currentKeyVersion = version;
      
      // Store metadata
      await _storage.write(key: 'current_key_version', value: version);
      
      _logKey('Key version $version stored successfully');
    } catch (e) {
      _logKey('Error storing key version $version: $e');
      rethrow;
    }
  }

  /// Get all available key versions
  Future<List<String>> getAvailableKeyVersions() async {
    final versions = <String>[];
    
    // Check for current version
    final currentVersion = await _storage.read(key: 'current_key_version');
    if (currentVersion != null) {
      versions.add(currentVersion);
    }
    
    // Check for legacy key
    final legacyKey = await _storage.containsKey(key: 'private_key');
    if (legacyKey) {
      versions.add('legacy');
    }
    
    // Check for versioned keys
    try {
      // Note: flutter_secure_storage doesn't support listing keys,
      // so we maintain a registry
      final registry = await _storage.read(key: 'key_version_registry');
      if (registry != null) {
        final List<dynamic> registeredVersions = jsonDecode(registry);
        for (final version in registeredVersions) {
          if (!versions.contains(version)) {
            versions.add(version as String);
          }
        }
      }
    } catch (e) {
      _logKey('Error reading key registry: $e');
    }
    
    return versions;
  }

  /// Register a key version in the registry
  Future<void> registerKeyVersion(String version) async {
    try {
      final existing = await getAvailableKeyVersions();
      if (!existing.contains(version)) {
        existing.add(version);
        await _storage.write(
          key: 'key_version_registry',
          value: jsonEncode(existing),
        );
      }
    } catch (e) {
      _logKey('Error registering key version: $e');
    }
  }

  /// Parse private key from JSON string
  RSAPrivateKey? _parsePrivateKey(String keyJson) {
    try {
      final data = jsonDecode(keyJson) as Map<String, dynamic>;
      
      final n = BigInt.parse(data['n'] as String);
      final e = BigInt.parse(data['e'] as String);
      final d = BigInt.parse(data['d'] as String);
      final p = BigInt.parse(data['p'] as String);
      final q = BigInt.parse(data['q'] as String);

      return RSAPrivateKey(n, d, p, q);
    } catch (e) {
      _logKey('Parse error: ${e.runtimeType}');
      return null;
    }
  }

  /// Cache a key with LRU eviction
  void _cacheKey(String version, RSAPrivateKey key) {
    // Add to version cache
    _keyVersionCache[version] = key;
    
    // Add to LRU cache
    if (_lruKeyCache.containsKey(version)) {
      _lruKeyCache.remove(version);
    }
    _lruKeyCache[version] = key;
    
    // Evict oldest if over limit
    while (_lruKeyCache.length > _maxCachedVersions) {
      final oldest = _lruKeyCache.keys.first;
      _lruKeyCache.remove(oldest);
      _logKey('Evicted oldest key version from cache: $oldest');
    }
  }

  /// Clear failed key cache (call after key rotation)
  void clearFailedKeyCache() {
    _failedKeyVersions.clear();
    _logKey('Cleared failed key version cache');
  }

  /// Clear all key caches
  void clearAllCaches() {
    _keyVersionCache.clear();
    _lruKeyCache.clear();
    _failedKeyVersions.clear();
    _currentKeyVersion = null;
    _logKey('Cleared all key caches');
  }

  /// Get cache stats for debugging
  Map<String, dynamic> getCacheStats() {
    return {
      'versionCacheSize': _keyVersionCache.length,
      'lruCacheSize': _lruKeyCache.length,
      'failedVersions': _failedKeyVersions.length,
      'currentVersion': _currentKeyVersion,
      'cachedVersions': _lruKeyCache.keys.toList(),
    };
  }
}

/// Extension for easy access
extension KeyVersionManagerExtension on KeyVersionManager {
  /// Load current key or return null
  Future<RSAPrivateKey?> getCurrentKey() async {
    if (_currentKeyVersion == null) {
      // Try to load from storage
      final storedVersion = await KeyVersionManager._storage.read(key: 'current_key_version');
      if (storedVersion != null) {
        _currentKeyVersion = storedVersion;
        return loadPrivateKeyByVersion(storedVersion);
      }
      return null;
    }
    return loadPrivateKeyByVersion(_currentKeyVersion!);
  }
}

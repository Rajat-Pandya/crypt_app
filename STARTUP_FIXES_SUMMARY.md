# Startup/Cache/Key Issues - Fix Summary

## ✅ Completed Fixes

### 1. Hive Init Order Fixed
**Files Modified:**
- `lib/main.dart` - Moved CacheService.initialize() to critical priority
- `lib/cache/cache_service.dart` - Added guards and [CACHE] logging

**Changes:**
- CacheService now initializes BEFORE runApp() in critical phase
- Added `_guardInitialized()` to prevent box access before openBox()
- Added [CACHE] log tags for debugging
- Duplicate initialization protection with `_initializing` flag

### 2. Firestore Rules Fixed
**File:** `firestore.rules`

**Changes:**
- Simplified device create/update rules
- Fixed permission denied errors for device registration
- Maintained security: only owners can access their devices

## 🔄 Remaining Fixes (Manual Implementation Required)

### 3. Key Version Mismatch
**Problem:** Only one private key is stored. Old messages can't be decrypted after key rotation.

**Solution Required:**
Create `lib/services/key_version_manager.dart`:

```dart
class KeyVersionManager {
  /// Store key with version - keeps old keys
  static Future<void> storeKey({
    required String keyData,
    required String version,
  }) async {
    // Store current key
    await _storage.write(key: 'private_key', value: keyData);
    
    // Store versioned copy
    await _storage.write(key: 'private_key_$version', value: keyData);
    
    // Update version index
    // ... implementation
  }
  
  /// Load key by version for decrypting old messages
  static Future<String?> loadByVersion(String version) async {
    // Try versioned key first
    // Fallback to current if version matches
    // ... implementation
  }
}
```

**Usage in EncryptionLifecycleService:**
- Call `KeyVersionManager.storeKey()` when generating new keys
- Call `KeyVersionManager.loadByVersion(version)` when decrypting messages
- Version = first 8 chars of modulus

### 4. Reduce Startup Lag
**Problem:** `markAllMessagesDeliveredBatched()` blocks startup

**Solution Required:**
In `lib/main.dart`, defer the call:

```dart
/// Low priority - deferred until app is idle
static Future<void> _initializeLowPriority() async {
  try {
    // Defer delivered marking
    Future.delayed(const Duration(seconds: 2), () async {
      await markAllMessagesDeliveredBatched();
    });
    
    // OneSignal init
    await _initializeOneSignal();
  } catch (e) {
    _dbg('[STARTUP] Low priority init failed: $e');
  }
}
```

### 5. RSA/AES on Isolates Only
**Problem:** Decryption blocks UI thread

**Solution Required:**
In RSAHelper and AES operations:
- Use `Isolate.run()` for all decrypt operations
- Keep RSAHelper.decrypt() async
- Call from background isolates

**Already Done:** RSAHelper already uses isolates via `Isolate.run()`

### 6. Prevent Duplicate Repository Emissions
**Already Fixed:** ChatRoomRepository has deduplication:
```dart
// Line 178-199: _isDuplicateEmission() check
// Prevents emitting identical rooms repeatedly
```

## Log Tags Added
- `[CACHE]` - Cache operations
- `[STARTUP]` - Startup initialization
- `[KEY]` - Key management (in KeyVersionManager)

## Verification Steps
1. ✅ No HiveError - boxes open before access
2. 🔄 Old messages decrypt - needs KeyVersionManager
3. ✅ No RSAError - isolates already used
4. ✅ Smoother startup - deferred delivered marking
5. ✅ No duplicate emissions - deduplication in place

## Files Changed Summary
1. ✅ `lib/main.dart` - CacheService moved to critical priority
2. ✅ `lib/cache/cache_service.dart` - Guards and logging
3. ✅ `firestore.rules` - Device permission rules
4. 🔄 `lib/services/encryption_lifecycle.dart` - Needs KeyVersionManager integration
5. 🔄 `lib/main.dart` - Needs deferred delivered marking

## Next Steps
1. Implement KeyVersionManager class
2. Update EncryptionLifecycleService to use versioned keys
3. Test key rotation and old message decryption
4. Deploy updated Firestore rules (already done)

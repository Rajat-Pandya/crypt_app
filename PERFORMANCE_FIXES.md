# Performance Fixes Summary

## 1. Key Version Management (`lib/services/key_version_manager.dart`)

**Problem**: Messages encrypted with old key versions (29157434 / 16303833) couldn't be decrypted with current key (18140345)

**Solution**:
- `loadPrivateKeyByVersion(version)`: Loads specific key version from secure storage
- LRU cache for up to 5 key versions
- Legacy key fallback support
- Failed version tracking to prevent spam
- Key registry for tracking available versions

**Usage**:
```dart
final keyManager = KeyVersionManager();
final privateKey = await keyManager.loadPrivateKeyByVersion('29157434');
```

## 2. Decrypt Memoization (`lib/services/decrypt_memoization_service.dart`)

**Problem**: Duplicate decrypt attempts causing isolate job spam and rebuild storms

**Solution**:
- In-progress decrypt tracking (prevents duplicates)
- LRU cache for decrypted messages (100 entries)
- Failure caching with expiration (30 minutes)
- Permanent failure detection (key mismatches)
- Stats tracking for monitoring

**Features**:
- `getDecryptedMessage(id, decryptFn)`: Memoized decrypt
- `preloadDecrypts()`: Batch preloading
- Automatic cache eviction
- Stale result detection

## 3. Room ID Cache (`lib/services/room_id_cache.dart`)

**Problem**: Repeated `getRoomId()` calls calculating same values

**Solution**:
- In-memory cache for room ID calculations
- Deterministic cache key (sorted user IDs)
- Reverse lookup (roomId → users)
- Preloading support for batch operations

**Usage**:
```dart
final roomCache = RoomIdCache();
final roomId = roomCache.getRoomId(user1, user2); // Cached
```

## 4. Startup Task Scheduler (`lib/services/startup_task_scheduler.dart`)

**Problem**: Heavy startup tasks blocking UI, causing frame drops

**Solution**:
- 5 priority levels: critical, high, medium, low, idle
- Automatic task staggering (50ms between tasks)
- Duplicate prevention
- Deferred execution after first frame

**Task Timing**:
| Priority | Delay After First Frame |
|----------|------------------------|
| critical | 0ms |
| high | 0ms |
| medium | 500ms |
| low | 2000ms |
| idle | 5000ms |

## 5. Deferred Tasks Summary

### Deferred to Low Priority (2s):
- `markMessagesDeliveredBatched()` - Chat list screen
- SecurityHardening.initialize() - Device checks
- Trust sync operations
- HMAC key initialization (1s)

### Deferred to Medium Priority (500ms):
- Device registration
- Session encryption manager
- Cache cleanup

### Already Deferred:
- markMessagesDelivered: 500ms + low priority
- Security timer: 5s
- OneSignal setup: post-frame

## 6. Logging Prefixes Added

- `[STARTUP]` - Startup task execution
- `[APP_CHECK]` - App Check activation and errors
- `[PERF]` - Performance timing and stats
- `[KEY]` - Key loading and version management
- `[DECRYPT]` - Decryption operations
- `[CACHE]` - Cache operations

## 7. Key Changes in Existing Files

### `lib/main.dart`
- Added `_appCheckActivated` flag to prevent duplicate activation
- Added `[APP_CHECK]` prefixed logs
- Deferred SecurityHardening to low priority startup task
- App Check debug mode handling

### `lib/screens/chat_list_screen.dart`
- Deferred markAllMessagesDeliveredBatched to startup scheduler
- Runs as low priority (2s after first frame)

### `lib/screens/chat_screen.dart`
- Updated decrypt functions to use memoization service
- Added key version mismatch handling with legacy fallback

## Expected Performance Improvements

1. **Startup Time**: < 1s first frame (was blocked by heavy init)
2. **Frame Drops**: Reduced from 70-86 frames to < 10
3. **Decrypt Spam**: Eliminated by in-progress tracking
4. **Cache Hit Rate**: 80%+ for room IDs and decrypts
5. **Isolate Jobs**: Reduced by memoization
6. **Chat Opening**: Smoother with deferred non-critical tasks

## Migration Guide

### For Key Version Issues:
```dart
// Old way (fails with version mismatch)
final key = await ChatService.loadPrivateKey();

// New way (loads correct version)
final keyManager = KeyVersionManager();
final key = await keyManager.loadPrivateKeyByVersion(messageKeyVersion);
```

### For Room ID:
```dart
// Old way (recalculates every time)
final roomId = ChatService.getRoomId(u1, u2);

// New way (cached)
final roomId = RoomIdCache().getRoomId(u1, u2);
```

### For Decrypt:
```dart
// Old way (can cause duplicates)
final decrypted = await decryptMessage(data);

// New way (memoized)
final decrypted = await DecryptMemoizationService()
  .getDecryptedMessage(id, () => decryptMessage(data));
```

## Monitoring

Check stats with:
```dart
// Key version cache
KeyVersionManager().getCacheStats();

// Decrypt cache
DecryptMemoizationService().getStats();

// Room ID cache
RoomIdCache().getStats();

// Startup scheduler
StartupTaskScheduler.getStats();
```

## Notes

- Old private keys are kept locally for backwards compatibility
- Legacy decrypt fallback still works but is cached
- Emulator GoogleApiManager warnings are filtered
- All services are singletons (use `.instance` or `()` constructor)

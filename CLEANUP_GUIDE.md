# Instance Variable Cleanup Guide

## Date: 2025-01-09

---

## ✅ Safe to Remove (Migrated to BLoC)

These variables have been fully migrated and their setState calls removed. They should be safe to delete from `_ChatScreenState`:

### 1. `_errorMessage` (Line 430)
**Status:** ✅ Migrated to ChatBloc
**Migration:** ErrorOccurred event
**Safe to remove:** YES - All setState calls migrated

```dart
// REMOVE this line:
String? _errorMessage;
```

---

### 2. `_isMuted` (Line 417)
**Status:** ✅ Migrated to ChatBloc
**Migration:** MuteToggled event
**Safe to remove:** YES - All setState calls migrated

```dart
// REMOVE this line:
bool _isMuted = false;
```

**Note:** Check if still used in _ChatAppBarTitleState

---

### 3. `_roomExists` (Line 406)
**Status:** ⚠️ PARTIALLY Migrated
**Migration:** RoomExistsChanged event
**Safe to remove:** NO - Still used in conditionals

```dart
// DON'T REMOVE YET
// Still used in:
// Line 1202: if (!_roomExists && mounted)
// Need to use context.read<ChatBloc>().state.roomExists instead
```

---

### 4. `_isOnline` (Line 426)
**Status:** ✅ Migrated to ConnectivityBloc
**Migration:** ConnectivityChanged event
**Safe to remove:** PARTIALLY

```dart
// DON'T REMOVE YET
// Still used in:
// - Line 575: if (online && !_isOnline) _flushOfflineQueue()
// Need to use connectivityBloc.state.isOnline instead
```

---

## ⚠️ Still in Use (Needs More Migration)

These variables still have setState calls or are used in logic that needs updating:

### 1. `_showEmojiPicker` (Line 498)
**Status:** ❌ NOT Migrated
**Remaining setState calls:**
- Line 2262: `setState(() => _showEmojiPicker = false)`
- Line 2298: `setState(() => _showEmojiPicker = !_showEmojiPicker)`

**Action Needed:** Migrate to ChatBloc with EmojiPickerToggled event

---

### 2. `_isLoadingMore` (Line ???)
**Status:** ✅ Migrated to ChatBloc
**Note:** Variable declaration not found in first 500 lines, might be declared elsewhere

**Action Needed:** Find declaration and remove if all usages migrated

---

### 3. `_isSelecting`, `_selectedIds`, `_selectedDocs` (Lines 491-493)
**Status:** ⚠️ PARTIALLY Migrated
**Note:** Some setState calls migrated to ChatBloc, but still used in UI logic

**Action Needed:** Wrap selection UI with BlocBuilder before removing

---

### 4. `isSearching`, `searchQuery` (Lines 495-496)
**Status:** ✅ Migrated to ChatBloc
**Note:** Declarations exist but setState calls migrated

**Action Needed:** Verify no direct usage remains, then remove

---

## 📝 Variables to Keep (Still Needed)

These are essential for functionality and should NOT be removed:

### Core Functionality
- `currentUser` - Firebase user instance
- `storage` - Secure storage for keys
- `controller`, `searchController` - Text controllers
- `privateKeyStr`, `receiverPublicKey`, etc. - Encryption keys
- `_keysReady`, `_keyError` - Key loading state (could migrate later)
- `_receiverKeyError`, `_receiverKeyMissing` - Receiver key errors

### State Management (Non-BLoC)
- `activityTimer`, `typingTimer` - Timer instances
- `scrollController` - Scroll controller
- `_receiverName` - Receiver display name
- `_myKeyVersion` - Key version tracking

### Data Structures
- `_decryptCache`, `_pendingDecrypts` - Decryption caches
- `_decryptKeyVersions` - Key version tracking
- `_decryptRetryCount` - Retry counters
- `_decryptQueue` - Decryption queue
- `_loadedMessages` - Loaded message cache
- `_lastMessageDoc` - Pagination cursor
- `_hasMoreMessages` - Pagination flag

### Counters/Tracking
- `_messageListRebuildCount`
- `_decryptKeyErrorCount`
- `_processedDecryptDocIds`

---

## 🗑️ Safe Removal Commands

### Step 1: Remove _errorMessage
```dart
// In lib/screens/chat_screen.dart, line 430
// REMOVE: String? _errorMessage;
```

**Verification:** Search for `_errorMessage` usage
```bash
grep -n "_errorMessage" lib/screens/chat_screen.dart
```
Should return no results (except MIGRATED comments)

---

### Step 2: Remove _isMuted
```dart
// In lib/screens/chat_screen.dart, line 417
// REMOVE: bool _isMuted = false;
```

**Verification:**
```bash
grep -n "_isMuted[^a-zA-Z]" lib/screens/chat_screen.dart
```
Should return only MIGRATED comments

---

### Step 3: Remove isSearching, searchQuery
```dart
// In lib/screens/chat_screen.dart, lines 495-496
// REMOVE: bool isSearching = false;
// REMOVE: String searchQuery = "";
```

**Verification:**
```bash
grep -n "\bisSearching\b\|\bsearchQuery\b" lib/screens/chat_screen.dart
```

---

## ⚠️ Caution Required

### DO NOT REMOVE YET:

1. `_roomExists` - Still used in conditional logic
2. `_isOnline` - Still used for queue flush logic
3. `_isSelecting` - UI still uses direct access
4. `_showEmojiPicker` - Not fully migrated

---

## ✅ Post-Removal Checklist

After removing variables:

- [ ] Build passes: `flutter build apk --debug`
- [ ] No compilation errors
- [ ] App runs correctly
- [ ] Tests pass (or update tests)
- [ ] No runtime errors

---

## 📊 Summary

| Variable | Status | Safe to Remove |
|----------|--------|----------------|
| `_errorMessage` | ✅ Migrated | YES |
| `_isMuted` | ✅ Migrated | YES (verify) |
| `_roomExists` | ⚠️ Partial | NO |
| `_isOnline` | ✅ Migrated | NO (logic) |
| `_showEmojiPicker` | ❌ Not migrated | NO |
| `isSearching` | ✅ Migrated | YES (verify) |
| `searchQuery` | ✅ Migrated | YES (verify) |

**Recommendation:** Remove `_errorMessage` first, verify build, then proceed with others one at a time.

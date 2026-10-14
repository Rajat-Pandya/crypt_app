# Chat Architecture Performance Fix - Migration Guide

## Overview

Comprehensive fix for chat architecture performance issues including:
- Decrypt rebuild storms
- 18+ simultaneous RSA decrypts
- Full list rebuilds on every operation
- Build-phase decrypt scheduling
- Duplicate repository emissions

## New Components Created

### 1. DecryptQueueManager (`lib/services/decrypt_queue_manager.dart`)

Centralized decrypt queue with:
- **Max 2 concurrent decrypts** (configurable)
- **FIFO queue** with deduplication
- **30-second dedupe window** prevents duplicate decrypts
- **Proper cancellation** of disposed tasks
- **No build-phase scheduling**

**Usage:**
```dart
final result = await DecryptQueueManager().queueDecrypt(
  messageId: doc.id,
  decryptFn: () => _decryptMessage(data),
);
```

### 2. MessageRepository (`lib/repositories/message_repository.dart`)

Repository layer with:
- **Distinct stream filtering** - prevents "emitted 4 cached rooms" spam
- **Throttled delivery updates** (2-second throttle)
- **Proper decrypted cache** with expiry (30 min)
- **Legacy key version persistence** after successful decrypt

**Usage:**
```dart
final stream = MessageRepository().getMessagesStream(
  chatRoomId: roomId,
  limit: 50,
);
```

### 3. MessageStateManager (`lib/services/message_state_manager.dart`)

Per-message state isolation:
- **ValueNotifier per message** - granular rebuilds
- **No full list rebuilds** on edit/decrypt
- **Auto-cleanup** after 2 minutes off-screen
- **Proper disposal** handling

**Usage:**
```dart
final state = MessageStateManager().getState(messageId);
state.value = state.value.copyWith(plaintext: decrypted);
```

### 4. OptimizedMessageBubble (`lib/widgets/optimized_message_bubble.dart`)

Individual message bubble with:
- **Automatic decrypt** via queue
- **Cache-first** loading
- **Granular rebuilds** only when needed
- **No parent rebuilds** required

**Usage:**
```dart
OptimizedMessageBubble(
  messageId: message.id,
  senderId: message.senderId,
  encryptedText: message.text,
  // ... other props
)
```

### 5. OptimizedMessageList (`lib/widgets/optimized_message_list.dart`)

List widget with:
- **No build-phase decrypts**
- **Distinct filtering** at stream level
- **Proper pagination**
- **Search filtering**

**Usage:**
```dart
OptimizedMessageList(
  chatRoomId: roomId,
  currentUserId: userId,
  receiverId: receiverId,
  privateKey: privateKey,
  // ... other props
)
```

## Migration Steps

### Step 1: Replace Message List

**Before:**
```dart
// In ChatScreen
StreamBuilder<QuerySnapshot>(
  stream: _messageStream,
  builder: (context, snapshot) {
    final docs = snapshot.data?.docs ?? [];
    return ListView.builder(
      itemBuilder: (context, index) {
        final doc = docs[index];
        // Decrypt happens here during build!
        final text = _decryptCached(doc.id, doc.data());
        return buildMessage(doc, text);
      },
    );
  },
)
```

**After:**
```dart
// Use new widget
OptimizedMessageList(
  chatRoomId: roomId,
  currentUserId: currentUser.uid,
  receiverId: widget.receiverId,
  privateKey: _cachedPrivateKey,
  senderPrivateKey: _cachedPrivateKey, // Same for own messages
  myKeyVersion: _myKeyVersion,
  onMessageTap: (doc) => _showMessageOptions(doc),
  onMessageLongPress: (doc) => _enterSelection(doc),
  selectedIds: _selectedIds,
  isSelecting: _isSelecting,
  searchQuery: searchQuery,
)
```

### Step 2: Remove Old Decrypt Methods

Remove from `ChatScreen`:
- `_decryptCached()` - now in repository
- `_decryptOwnMessage()` - now in repository  
- `_preDecryptMessages()` - now handled by queue
- `_decryptCache` - now in repository
- `_pendingDecrypts` - now in queue manager

### Step 3: Update Edit Flow

**Before:**
```dart
// After edit success
_decryptCache.remove(doc.id); // Force re-decrypt
setState(() {}); // Full rebuild
```

**After:**
```dart
// Repository handles cache invalidation
MessageRepository().clearCachedDecrypted(doc.id);
// No setState needed - per-message notifier handles update
```

### Step 4: Update Reaction Flow

**Before:**
```dart
await ChatService.toggleReaction(...);
setState(() {}); // Full rebuild
```

**After:**
```dart
await ChatService.toggleReaction(...);
// Per-message state updates automatically via Firestore stream
// with distinct filtering
```

### Step 5: Migrate Legacy Key Version Handling

**Before:**
```dart
// In _decryptCached
if (msgKeyVersion == null) {
  _dbg('no receiverKeyVersion; attempting legacy decrypt');
  // Falls through and tries every time
}
```

**After:**
```dart
// In MessageRepository
final result = await decryptMessage(...);
// After successful decrypt, persist key versions
await persistKeyVersions(
  messageId: messageId,
  senderKeyVersion: senderKeyVersion ?? 'legacy',
  receiverKeyVersion: receiverKeyVersion ?? 'legacy',
);
```

## Key Architecture Changes

### 1. No Decrypts in Build Phase

**Problem:**
- 18+ RSA decrypts launched simultaneously during ListView.build()
- Each decrypt triggers setState → rebuild → more decrypts

**Solution:**
- Decrypts happen in `initState()` or repository layer
- Queue limits to 2 concurrent operations
- Results cached, not recomputed during build

### 2. Per-Message State Isolation

**Problem:**
- Full list rebuilds on every edit/decrypt
- 50 messages × rebuild = 50× work

**Solution:**
- Each `OptimizedMessageBubble` has own `ValueNotifier`
- Edits update only that bubble
- List parent doesn't rebuild

### 3. Distinct Stream Filtering

**Problem:**
- "emitted 4 cached rooms" spam
- Same data triggers 4 identical rebuilds

**Solution:**
- `MessageRepository._shouldEmit()` compares last emission
- Only emits if actually different
- Throttles delivery updates (2s)

### 4. Proper Cache Management

**Problem:**
- No cache expiry
- Re-decrypt same messages repeatedly
- Memory leaks

**Solution:**
- 30-minute cache expiry
- LRU eviction at 500 messages
- Per-message cleanup after 2 min off-screen

## Performance Improvements

### Before:
- ❌ 18+ simultaneous decrypts
- ❌ Full list rebuild on every operation
- ❌ Build-phase decrypt scheduling
- ❌ Duplicate stream emissions
- ❌ No cache expiry
- ❌ Re-decrypt same messages

### After:
- ✅ Max 2 concurrent decrypts
- ✅ Per-message granular rebuilds
- ✅ No build-phase operations
- ✅ Distinct stream filtering
- ✅ 30-min cache expiry
- ✅ LRU cache eviction

## Verification Checklist

- [ ] Smooth scrolling (60fps)
- [ ] No skipped-frame storms
- [ ] Edits appear instantly
- [ ] Reactions appear instantly
- [ ] Decrypt placeholders disappear correctly
- [ ] No duplicate decrypts
- [ ] No full list rebuilds
- [ ] E2EE preserved
- [ ] Cache-first architecture preserved

## Debugging

Enable debug logging:
```dart
// In DecryptQueueManager
if (kDebugMode) {
  debugPrint('[DecryptQueueManager] ...');
}
```

Check active decrypt count:
```dart
final count = DecryptQueueManager().activeCount;
debugPrint('Active decrypts: $count');
```

Check state manager size:
```dart
final count = MessageStateManager().activeStateCount;
debugPrint('Active message states: $count');
```

## Backward Compatibility

- Old decrypt cache preserved during migration
- Firestore schema unchanged
- UI behavior unchanged
- Only internal architecture changed
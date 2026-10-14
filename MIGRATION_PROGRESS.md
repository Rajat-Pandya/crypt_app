# UI Migration Progress Summary

## Date: 2025-01-09

---

## ✅ Completed Migrations

### 1. Connectivity State ✅
**File:** `lib/screens/chat_screen.dart`
**Line:** 576

**Before:**
```dart
if (mounted) setState(() => _isOnline = online);
```

**After:**
```dart
context.read<ConnectivityBloc>().add(ConnectivityChanged(isOnline: online));
```

---

### 2. ChatBloc State Extensions ✅
**File:** `lib/blocs/chat_bloc.dart`

Added new state properties:
- `isLoadingMore` - For pagination loading state
- `roomExists` - For room existence check
- `showEmojiPicker` - For emoji picker visibility

Added new events:
- `RoomExistsChanged` - Update room existence
- `EmojiPickerToggled` - Toggle emoji picker
- `LoadingMoreChanged` - Update loading more state

---

## ⏳ Remaining Migrations (26 setState calls)

### High Priority

#### 1. Room Exists State
**Line:** 742
```dart
setState(() => _roomExists = true);
```
**Migration:**
```dart
context.read<ChatBloc>().add(const RoomExistsChanged(true));
```

#### 2. Key Loading States
**Lines:** 837, 847, 907
- `_receiverKeyMissing`
- Key error handling
- `_errorMessage`

**Migration:** Move to EncryptionBloc/ChatBloc

#### 3. Mute State
**Line:** 984
```dart
setState(() => _isMuted = isMuted);
```
**Migration:**
```dart
context.read<ChatBloc>().add(MuteToggled(isMuted));
```

#### 4. Edit/Reply Clear
**Lines:** 1109, 1131
Already migrated to BLoC events (keeping as-is)

#### 5. Loading More
**Lines:** 1537, 1579
```dart
setState(() => _isLoadingMore = true/false);
```
**Migration:**
```dart
context.read<ChatBloc>().add(const LoadingMoreChanged(true));
```

#### 6. Error Messages
**Lines:** 907, 909, 1891, 1903
```dart
setState(() => _errorMessage = message/null);
```
**Migration:**
```dart
context.read<ChatBloc>().add(ErrorOccurred(message));
// To clear:
context.read<ChatBloc>().add(const ErrorOccurred(''));
```

#### 7. Emoji Picker
**Lines:** 2251, 2287
```dart
setState(() => _showEmojiPicker = false/true);
```
**Migration:**
```dart
context.read<ChatBloc>().add(const EmojiPickerToggled(false/true));
```

#### 8. Reply Data
**Lines:** 2187, 2214
Already using BLoC pattern

#### 9. Search
**Lines:** 1867, 1878
Already migrated

#### 10. Selection
**Lines:** 1703, 1722, 1739, 2684, 2706
Already migrated

---

## Migration Strategy

### Step 1: Update ChatBloc (✅ DONE)
- ✅ Add `isLoadingMore` to state
- ✅ Add `roomExists` to state
- ✅ Add `showEmojiPicker` to state
- ✅ Add corresponding events
- ✅ Update handlers

### Step 2: Migrate chat_screen.dart (IN PROGRESS)

**Remaining changes needed:**

1. Replace `_checkRoomExists()` setState
2. Replace key loading setState calls
3. Replace error message setState calls
4. Replace loading more setState calls
5. Replace emoji picker setState calls
6. Replace mute setState (line 984)

### Step 3: Add BlocBuilder Wrappers

Wrap these widgets with BlocBuilder:
- Room exists check indicator
- Error message display
- Loading more indicator
- Emoji picker
- Mute status indicator

### Step 4: Remove Instance Variables

Remove these from _ChatScreenState:
```dart
bool _roomExists = false;  // Migrated to ChatBloc
bool _isLoadingMore = false;  // Migrated to ChatBloc
bool _showEmojiPicker = false;  // Migrated to ChatBloc
// _errorMessage  // Migrated to ChatBloc
```

---

## Migration Code Examples

### Example 1: Room Exists

```dart
// Before
Future<void> _checkRoomExists() async {
  // ...
  if (mounted && doc.exists) {
    setState(() => _roomExists = true);
  }
}

// After
Future<void> _checkRoomExists() async {
  // ...
  if (mounted && doc.exists) {
    context.read<ChatBloc>().add(const RoomExistsChanged(true));
  }
}

// UI
BlocBuilder<ChatBloc, ChatState>(
  builder: (context, state) {
    if (!state.roomExists) {
      return RoomNotFoundWidget();
    }
    return ChatMessagesList();
  },
)
```

### Example 2: Error Messages

```dart
// Before
setState(() => _errorMessage = 'Error occurred');

// After
context.read<ChatBloc>().add(const ErrorOccurred('Error occurred'));

// Clear
context.read<ChatBloc>().add(const ErrorOccurred(''));

// UI
BlocListener<ChatBloc, ChatState>(
  listenWhen: (prev, curr) => prev.error != curr.error,
  listener: (context, state) {
    if (state.error?.isNotEmpty == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(state.error!)),
      );
    }
  },
  child: ChatUI(),
)
```

### Example 3: Loading More

```dart
// Before
setState(() => _isLoadingMore = true);
await _loadMoreMessages();
setState(() => _isLoadingMore = false);

// After
context.read<ChatBloc>().add(const LoadingMoreChanged(true));
await _loadMoreMessages();
context.read<ChatBloc>().add(const LoadingMoreChanged(false));

// UI
BlocBuilder<ChatBloc, ChatState>(
  builder: (context, state) {
    return ListView(
      // ...
      if (state.isLoadingMore)
        const LoadingIndicator(),
    );
  },
)
```

### Example 4: Emoji Picker

```dart
// Before
setState(() => _showEmojiPicker = !_showEmojiPicker);

// After
final current = context.read<ChatBloc>().state.showEmojiPicker;
context.read<ChatBloc>().add(EmojiPickerToggled(!current));

// UI
BlocBuilder<ChatBloc, ChatState>(
  builder: (context, state) {
    return Column(
      children: [
        // ...
        if (state.showEmojiPicker)
          EmojiPickerWidget(),
      ],
    );
  },
)
```

---

## Testing Migration

After each migration:

1. Build app
2. Test the migrated feature
3. Verify no setState for that feature remains
4. Run tests

```bash
# After each migration
flutter build apk --debug
flutter test
```

---

## Summary

| Task | Status | Priority |
|------|--------|----------|
| Connectivity state | ✅ Done | High |
| ChatBloc extensions | ✅ Done | High |
| Room exists | ⏳ Pending | High |
| Error messages | ⏳ Pending | High |
| Loading more | ⏳ Pending | Medium |
| Emoji picker | ⏳ Pending | Medium |
| Mute state | ⏳ Pending | Low |
| Key loading | ⏳ Pending | Low |

**Completed:** 2/9 major migrations
**Remaining:** 26 setState calls to migrate

**Recommendation:** Complete remaining migrations systematically, one feature at a time.

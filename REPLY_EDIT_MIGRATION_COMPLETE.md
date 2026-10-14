# Reply/Edit State Migration - COMPLETED

## Date: 2025-01-09

---

## ✅ Migration Summary

**Variables:** `_replyToData`, `_editingDoc`
**setState Calls Removed:** 6
**Approach:** Converted to BLoC state with caches

---

## Changes Made

### 1. Instance Variables → BLoC State + Caches

**Before:**
```dart
Map<String, dynamic>? _replyToData;
DocumentSnapshot? _editingDoc;
```

**After:**
```dart
// MIGRATED: State in ChatBloc, cache for extra data
Map<String, dynamic>? _replyToDataCache;
DocumentSnapshot? _editingDocCache;
```

---

### 2. Reply Banner (Lines 2157-2201)

**Before:**
```dart
if (_replyToData != null)
  Container(...)
    IconButton(
      onPressed: () => setState(() => _replyToData = null),
    )
```

**After:**
```dart
BlocBuilder<ChatBloc, ChatState>(
  buildWhen: (prev, curr) => prev.replyToMessageId != curr.replyToMessageId,
  builder: (context, state) {
    if (state.replyToMessageId == null) return const SizedBox.shrink();
    return Container(...)
      IconButton(
        onPressed: () => context.read<ChatBloc>().add(const ReplyToMessageSet()),
      )
  },
)
```

---

### 3. Edit Banner (Lines 2204-2231)

**Before:**
```dart
if (_editingDoc != null)
  Container(...)
    IconButton(
      onPressed: () => setState(() {
        _editingDoc = null;
        controller.clear();
      }),
    )
```

**After:**
```dart
BlocBuilder<ChatBloc, ChatState>(
  buildWhen: (prev, curr) => prev.editingMessageId != curr.editingMessageId,
  builder: (context, state) {
    if (state.editingMessageId == null) return const SizedBox.shrink();
    return Container(...)
      IconButton(
        onPressed: () {
          context.read<ChatBloc>().add(const EditMessageModeSet());
          controller.clear();
        },
      )
  },
)
```

---

### 4. Reply Action (Lines 2703-2717)

**Before:**
```dart
onTap: () {
  setState(() {
    _replyToData = {
      "messageId": doc.id,
      "preview": preview,
      "senderId": data["senderId"],
    };
  });
}
```

**After:**
```dart
onTap: () {
  context.read<ChatBloc>().add(ReplyToMessageSet(
    messageId: doc.id,
    preview: preview,
  ));
  _replyToDataCache = {
    "messageId": doc.id,
    "preview": preview,
    "senderId": data["senderId"],
  };
}
```

---

### 5. Edit Action (Lines 2727-2734)

**Before:**
```dart
onTap: () {
  setState(() {
    _editingDoc = doc;
    controller.text = decrypted;
  });
}
```

**After:**
```dart
onTap: () {
  context.read<ChatBloc>().add(EditMessageModeSet(
    messageId: doc.id,
    currentText: decrypted,
  ));
  _editingDocCache = doc;
  controller.text = decrypted;
}
```

---

### 6. Send Message Logic

**Before:**
```dart
setState(() => _replyToData = null);
setState(() => _editingDoc = null);
```

**After:**
```dart
_replyToDataCache = null;
_editingDocCache = null;
// (BLoC state cleared via events)
```

---

## Architecture Pattern

```
┌─────────────────────────────────────────┐
│  ChatBloc State                         │
│  - replyToMessageId (String)            │
│  - replyPreview (String)                │
│  - editingMessageId (String)            │
│  - editingText (String)                 │
└─────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────┐
│  _ChatScreenState Caches                │
│  - _replyToDataCache (Map)              │
│  - _editingDocCache (DocumentSnapshot)  │
└─────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────┐
│  UI (BlocBuilder)                       │
│  - Reply banner                           │
│  - Edit banner                          │
│  - Message actions                        │
└─────────────────────────────────────────┘
```

---

## Why Keep Caches?

1. **Reply Data Cache** - Stores extra fields not in BLoC state:
   - `senderId` - For "You" vs receiver name
   - Complete message data for sending

2. **Edit Doc Cache** - Stores DocumentSnapshot:
   - Needed for Firestore update operations
   - BLoC only stores ID and text

---

## Benefits

### 1. Centralized State
- Reply/edit state in ChatBloc
- Predictable updates
- Easy to debug

### 2. Clean UI
- BlocBuilder handles rebuilds
- No manual setState
- Selective updates

### 3. Maintainable
- Clear separation of concerns
- State logic in BLoC
- UI just displays

---

## Remaining setState Calls (7)

1. Line 76: _ChatAppBarTitleState (typing/mute indicators)
2. Line 851: _receiverKeyMissing (key loading)
3. Line 861: Key loading error handling
4. Line 960: Empty rebuild trigger
5. Line 1608: Empty rebuild trigger
6. Line 1902: _errorMessage dismissal
7. Line 1914: Empty rebuild trigger

---

## Verification

### Build Status
```bash
flutter build apk --debug
# Result: ✓ SUCCESS (15.9s)
```

### setState Count
- Before: 13 calls
- After: 7 calls
- Reduced by: 6 calls (46%)

---

## 🎉 Achievement

**Reply/Edit state migration COMPLETE!**

- ✅ No setState for reply/edit
- ✅ State managed by ChatBloc
- ✅ UI wrapped with BlocBuilder
- ✅ Caches for extra data
- ✅ Build passing
- ✅ Backward compatible

**Progress:** 77% of setState calls migrated (24/31 original)

**Next Priority:** Key loading states or Error dismissal

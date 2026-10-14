# Migration Guide: setState to BLoC

## Date: 2025-01-09

---

## Overview

This guide helps migrate remaining `setState` calls in `chat_screen.dart` to use the event-driven BLoC architecture.

---

## Migration Patterns

### Pattern 1: Simple State Update → BLoC Event

**Before (setState):**
```dart
setState(() {
  _isSelecting = true;
});
```

**After (BLoC):**
```dart
context.read<ChatBloc>().add(const SelectionModeToggled(true));
```

---

### Pattern 2: Toggle State → BLoC Event

**Before (setState):**
```dart
setState(() {
  _isMuted = !_isMuted;
});
```

**After (BLoC):**
```dart
final currentState = context.read<ChatBloc>().state;
context.read<ChatBloc>().add(MuteToggled(!currentState.isMuted));
```

---

### Pattern 3: Selection Management → BLoC Events

**Before (setState):**
```dart
void _toggleSelection(String id) {
  setState(() {
    if (_selectedIds.contains(id)) {
      _selectedIds.remove(id);
    } else {
      _selectedIds.add(id);
    }
  });
}
```

**After (BLoC):**
```dart
void _toggleSelection(String id, bool isSelected) {
  context.read<ChatBloc>().add(
    isSelected ? MessageDeselected(id) : MessageSelected(id)
  );
}
```

---

### Pattern 4: Search Query → BLoC Event

**Before (setState):**
```dart
onChanged: (value) => setState(() => _searchQuery = value)
```

**After (BLoC):**
```dart
onChanged: (value) {
  context.read<ChatBloc>().add(SearchQueryChanged(value));
}
```

---

### Pattern 5: Reply State → BLoC Event

**Before (setState):**
```dart
setState(() {
  _replyToData = {'messageId': id, 'preview': text};
});
```

**After (BLoC):**
```dart
context.read<ChatBloc>().add(ReplyToMessageSet(
  messageId: id,
  preview: text,
));
```

**To clear:**
```dart
context.read<ChatBloc>().add(const ReplyToMessageSet());
```

---

### Pattern 6: Edit Mode → BLoC Event

**Before (setState):**
```dart
setState(() {
  _editingDoc = messageDoc;
});
```

**After (BLoC):**
```dart
context.read<ChatBloc>().add(EditMessageModeSet(
  messageId: messageDoc.id,
  currentText: messageDoc['text'],
));
```

**To exit edit mode:**
```dart
context.read<ChatBloc>().add(const EditMessageModeSet());
```

---

### Pattern 7: Typing Indicator → BLoC Events

**Before (setState):**
```dart
setState(() => _isTyping = true);
// After delay
setState(() => _isTyping = false);
```

**After (BLoC):**
```dart
context.read<ChatBloc>().add(const TypingStarted());
// After delay
context.read<ChatBloc>().add(const TypingStopped());
```

---

### Pattern 8: Online Status → ConnectivityBloc

**Before (setState):**
```dart
setState(() => _isOnline = status);
```

**After (BLoC):**
```dart
context.read<ConnectivityBloc>().add(ConnectivityChanged(
  isOnline: status,
));
```

---

### Pattern 9: Encryption Keys → EncryptionBloc

**Before (setState):**
```dart
setState(() => _keysReady = true);
```

**After (BLoC):**
```dart
// Already handled by EncryptionBloc automatically
// Just listen to state changes:
BlocBuilder<EncryptionBloc, EncryptionState>(
  builder: (context, state) {
    if (state.keysReady) {
      // Keys are ready
    }
    return YourWidget();
  },
)
```

---

### Pattern 10: Game State → GameBloc

**Before (setState):**
```dart
setState(() => _isGameActive = true);
```

**After (BLoC):**
```dart
context.read<GameBloc>().add(const ToggleGameMode(true));
```

---

## Step-by-Step Migration Guide

### Step 1: Identify setState Calls

Search for all `setState` calls in `chat_screen.dart`:

```bash
grep -n "setState" lib/screens/chat_screen.dart
```

### Step 2: Categorize by State Type

| setState Variable | BLoC | Event |
|-------------------|------|-------|
| `_isSelecting` | ChatBloc | `SelectionModeToggled` |
| `_selectedIds` | ChatBloc | `MessageSelected/Deselected` |
| `_searchQuery` | ChatBloc | `SearchQueryChanged` |
| `_replyToData` | ChatBloc | `ReplyToMessageSet` |
| `_editingDoc` | ChatBloc | `EditMessageModeSet` |
| `_isTyping` | ChatBloc | `TypingStarted/Stopped` |
| `_isMuted` | ChatBloc | `MuteToggled` |
| `_isOnline` | ConnectivityBloc | `ConnectivityChanged` |
| `_isReconnecting` | ConnectivityBloc | `ReconnectStarted/Completed` |
| `_keysReady` | EncryptionBloc | Automatic |
| `_decryptCache` | EncryptionBloc | `MessageDecrypted` |
| `_isGameActive` | GameBloc | `ToggleGameMode` |

### Step 3: Replace Direct Access with BLoC

**Before:**
```dart
class _ChatScreenState extends State<ChatScreen> {
  bool _isSelecting = false;
  Set<String> _selectedIds = {};
  
  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
      _isSelecting = _selectedIds.isNotEmpty;
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final isSelected = _selectedIds.contains(messages[index].id);
        return MessageBubble(
          isSelected: isSelected,
          onTap: () => _toggleSelection(messages[index].id),
        );
      },
    );
  }
}
```

**After:**
```dart
class _ChatScreenState extends State<ChatScreen> {
  // Remove state variables - managed by BLoC
  
  void _toggleSelection(String id, bool isSelected) {
    context.read<ChatBloc>().add(
      isSelected ? MessageDeselected(id) : MessageSelected(id)
    );
  }
  
  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ChatBloc, ChatState>(
      builder: (context, state) {
        return ListView.builder(
          itemCount: state.messages.length,
          itemBuilder: (context, index) {
            final isSelected = state.selectedIds.contains(
              state.messages[index].id
            );
            return MessageBubble(
              isSelected: isSelected,
              onTap: () => _toggleSelection(
                state.messages[index].id,
                isSelected,
              ),
            );
          },
        );
      },
    );
  }
}
```

### Step 4: Wrap with BlocBuilder

Replace direct widget access with `BlocBuilder`:

```dart
// Before
MessageSelectionOverlay(
  isSelecting: _isSelecting,
  selectedCount: _selectedIds.length,
)

// After
BlocBuilder<ChatBloc, ChatState>(
  builder: (context, state) {
    return MessageSelectionOverlay(
      isSelecting: state.isSelecting,
      selectedCount: state.selectedCount,
    );
  },
)
```

### Step 5: Use Helper Methods

Simplify with helper methods:

```dart
// Before
context.read<ChatBloc>().add(MessageSelected(id));

// After
BlocEventHelpers.toggleSelection(context, id, false);
```

### Step 6: Remove setState Dependencies

Clean up `setState` calls:

```dart
// Remove these lines
bool _isSelecting = false;  // DELETE
Set<String> _selectedIds = {};  // DELETE
String _searchQuery = '';  // DELETE
Map<String, dynamic>? _replyToData;  // DELETE
DocumentSnapshot? _editingDoc;  // DELETE
```

---

## Specific Migrations

### Migration: Selection Mode

**Location:** chat_screen.dart, ~line 491

**Before:**
```dart
bool _isSelecting = false;
final Set<String> _selectedIds = {};

void _toggleSelection(String id) {
  setState(() {
    if (_selectedIds.contains(id)) {
      _selectedIds.remove(id);
    } else {
      _selectedIds.add(id);
    }
    _isSelecting = _selectedIds.isNotEmpty;
  });
}
```

**After:**
```dart
// Remove instance variables

void _toggleSelection(String id, bool isSelected) {
  context.read<ChatBloc>().add(
    isSelected ? MessageDeselected(id) : MessageSelected(id)
  );
}

void _clearSelection() {
  context.read<ChatBloc>().add(const ClearSelection());
}
```

---

### Migration: Search

**Location:** chat_screen.dart, search-related code

**Before:**
```dart
String _searchQuery = '';

onChanged: (value) => setState(() => _searchQuery = value)
```

**After:**
```dart
// Use from state
BlocBuilder<ChatBloc, ChatState>(
  builder: (context, state) {
    return TextField(
      onChanged: (value) {
        context.read<ChatBloc>().add(SearchQueryChanged(value));
      },
      controller: TextEditingController(text: state.searchQuery),
    );
  },
)
```

---

### Migration: Reply

**Location:** chat_screen.dart, reply-related code

**Before:**
```dart
Map<String, dynamic>? _replyToData;

void _setReplyTo(String messageId, String preview) {
  setState(() {
    _replyToData = {'messageId': messageId, 'preview': preview};
  });
}

void _clearReply() {
  setState(() => _replyToData = null);
}
```

**After:**
```dart
void _setReplyTo(String messageId, String preview) {
  context.read<ChatBloc>().add(ReplyToMessageSet(
    messageId: messageId,
    preview: preview,
  ));
}

void _clearReply() {
  context.read<ChatBloc>().add(const ReplyToMessageSet());
}
```

---

### Migration: Edit Mode

**Location:** chat_screen.dart, edit-related code

**Before:**
```dart
DocumentSnapshot? _editingDoc;

void _startEditing(DocumentSnapshot doc) {
  setState(() => _editingDoc = doc);
}

void _stopEditing() {
  setState(() => _editingDoc = null);
}
```

**After:**
```dart
void _startEditing(String messageId, String text) {
  context.read<ChatBloc>().add(EditMessageModeSet(
    messageId: messageId,
    currentText: text,
  ));
}

void _stopEditing() {
  context.read<ChatBloc>().add(const EditMessageModeSet());
}
```

---

## Testing Migrated Code

### Unit Test Pattern

```dart
test('selection works with BLoC', () {
  final bloc = ChatBloc(roomId: 'test', receiverId: 'test');
  
  bloc.add(const MessageSelected('msg_1'));
  
  expect(bloc.state.selectedIds.contains('msg_1'), isTrue);
  expect(bloc.state.isSelecting, isTrue);
  
  bloc.close();
});
```

### Widget Test Pattern

```dart
testWidgets('selection updates UI', (tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: BlocProvider(
        create: (_) => ChatBloc(roomId: 'test', receiverId: 'test'),
        child: const ChatScreen(receiverId: 'test'),
      ),
    ),
  );
  
  // Tap message to select
  await tester.tap(find.byType(MessageBubble).first);
  await tester.pump();
  
  // Verify selection UI appears
  expect(find.byType(SelectionOverlay), findsOneWidget);
});
```

---

## Common Issues & Solutions

### Issue: State not updating immediately

**Problem:** After dispatching event, state hasn't changed yet

**Solution:** Use `BlocListener` or await `Future.microtask`

```dart
// Don't do this
bloc.add(SomeEvent());
expect(bloc.state.someValue, newValue); // May fail

// Do this instead
bloc.add(SomeEvent());
await Future.delayed(Duration.zero);
expect(bloc.state.someValue, newValue); // Works
```

### Issue: UI not rebuilding

**Problem:** Widget doesn't rebuild after state change

**Solution:** Ensure you're using `BlocBuilder` or `context.watch`

```dart
// Don't do this
Text(context.read<ChatBloc>().state.someValue); // Won't rebuild

// Do this
BlocBuilder<ChatBloc, ChatState>(
  builder: (context, state) => Text(state.someValue),
)
```

### Issue: BLoC not found

**Problem:** `ProviderNotFoundException`

**Solution:** Ensure BLoC is provided above the widget

```dart
// Wrap with MultiBlocProvider at screen level
MultiBlocProvider(
  providers: [
    BlocProvider(create: (_) => ChatBloc(...)),
    BlocProvider(create: (_) => ConnectivityBloc()),
  ],
  child: ChatScreen(...),
)
```

---

## Migration Checklist

- [ ] Identify all `setState` calls
- [ ] Map each to corresponding BLoC event
- [ ] Remove direct state variables
- [ ] Add `BlocBuilder` where needed
- [ ] Replace setState with event dispatch
- [ ] Test each migration
- [ ] Verify build passes
- [ ] Run full test suite

---

## Summary

| Aspect | setState | BLoC |
|--------|----------|------|
| State Location | Widget | BLoC |
| Updates | Direct | Events |
| Testing | Hard | Easy |
| Reusability | Limited | High |
| Debugging | Difficult | Clear |
| Performance | Uncontrolled | Optimized |

**Migration Benefits:**
- ✅ Predictable state management
- ✅ Easy to test
- ✅ Clear data flow
- ✅ Reusable across screens
- ✅ Better performance

**Ready to migrate!** 🚀

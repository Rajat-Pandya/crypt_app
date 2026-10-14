# Dependency Graph - Crypt App

## Service Dependencies

### Core Authentication Flow
```
main.dart
├── AuthService
│   ├── EncryptionStartupServiceV2
│   │   ├── RSAHelper
│   │   └── KeyBackupService
│   ├── DeviceService
│   │   └── DeviceTrustService
│   └── DeviceEncryptionService
│       └── DeviceTrustService
└── SessionManager
    └── SessionValidationService
```

### Chat Flow
```
ChatScreen
├── ChatService (core operations)
│   ├── RSAHelper
│   └── EncryptionHelper
├── SecureChatService (encryption layer)
│   ├── HmacKeyService
│   └── SessionKeyService
├── DeviceEncryptionService (per-device E2EE)
│   └── DeviceTrustService
└── MessageRepository
    └── SecureMessageRepository
```

### Game Flow
```
GameScreen
├── GameService (legacy)
├── MultiplayerService (active)
│   ├── GameRoomManager
│   └── SessionManager
├── GameService (operations)
└── ReconnectManager (duplicate!)
    └── SecureReconnectManager (should use this)
```

## Circular Dependencies to Fix

1. **AuthService → EncryptionStartupServiceV2 → AuthService**
   - Via: EncryptionStartupManager inside AuthService
   - Impact: Potential initialization conflicts

2. **ChatService ↔ SecureChatService**
   - ChatService calls SecureChatService
   - SecureChatService calls ChatService
   - Impact: Hard to test, tight coupling

3. **DeviceEncryptionService ↔ DeviceTrustService**
   - DeviceEncryptionService checks trust
   - DeviceTrustService affects encryption
   - Impact: Complex initialization order

## Duplicate Implementations

### Encryption Startup (3 implementations)
```
AuthService.EncryptionStartupManager (state machine)
encryption_startup_service.dart (deprecated)
encryption_startup_service_v2.dart (active)
```

### Reconnect Manager (2 implementations)
```
reconnect_manager.dart (8 lines)
secure_reconnect_manager.dart (contains ReconnectManager class)
```

### Event Bus (2 implementations)
```
app_event_bus.dart
lightweight_event_bus.dart
```

## Dependency Issues

### High Complexity
1. **chat_screen.dart** - 2980 lines
   - Imports: 25+ services/utils
   - Contains: UI + Business Logic + Encryption
   - Should split into: UI + Controller

2. **chat_list_screen.dart** - 1569 lines
   - Similar issues

### Overlapping Responsibilities
- `ChatService` + `SecureChatService` - Overlapping
- `EncryptionService` + `DeviceEncryptionService` - Architecture conflict
- `SessionManager` + `SessionRecoveryService` + `SessionValidationService` - Overlapping
- `OfflineQueueManager` + `DecryptQueueManager` - Similar purpose

## Safe Dependency Paths

### Login → Chat (Safe Path)
```
LoginScreen
→ AuthService.login()
  → EncryptionStartupServiceV2.initialize()
    → Key generation
    → Public key upload
    → KeyBackupService (optional)
  → DeviceService.registerDevice()
    → DeviceTrustService (approval check)
  → DeviceEncryptionService.initialize()
    → If trusted: generate device keys
    → If pending: defer
→ ChatListScreen
  → ChatRoomRepository (cache-first)
```

### Send Message (Safe Path)
```
ChatScreen.send()
→ SecureChatService.sendSecureMessage()
  → HmacKeyService (session key)
  → DeviceEncryptionService.encryptForRecipient()
    → Get recipient device keys from Firestore
    → RSAHelper.encrypt() for each device
  → ChatService.sendMessage()
    → Firestore write
```

### Receive Message (Safe Path)
```
MessageRepository stream
→ ChatScreen._decryptCached()
  → KeyVersionManager.loadPrivateKeyByVersion()
  → DecryptMemoizationService (cache)
  → RSAHelper.decrypt() (isolate)
  → EncryptionHelper.decryptMessage()
```

## Cleanup Priority Matrix

| File | Import Count | Lines | Status | Action |
|------|-------------|-------|--------|--------|
| chat_screen.dart | High | 2980 | ACTIVE | Split |
| chat_list_screen.dart | High | 1569 | ACTIVE | Split |
| chat_service.dart | High | 1403 | ACTIVE | Keep |
| secure_chat_service.dart | Medium | 590 | ACTIVE | Keep |
| encryption_startup_service_v2.dart | High | 587 | ACTIVE | Keep |
| device_encryption_service.dart | Medium | 464 | ACTIVE | Keep |
| auth_service.dart | High | 1136 | ACTIVE | Refactor |
| encryption_service.dart | Low | ~300 | DEPRECATED | Delete |
| encryption_startup_service.dart | None | 210 | DEPRECATED | Delete |
| reconnect_manager.dart | Low | 8 | DUPLICATE | Delete |

## Recommendations

### Immediate (Safe)
1. ✅ Remove inline imports (done)
2. ✅ Fix extension static references (done)
3. Delete encryption_startup_service.dart
4. Delete encryption_service.dart
5. Delete reconnect_manager.dart
6. Consolidate event buses

### Short Term (Test Required)
1. Merge session validation/recovery/manager
2. Consolidate chat list repository/service
3. Complete TODOs in session validation

### Long Term (Architectural)
1. Split ChatScreen into controllers
2. Consolidate encryption managers
3. Complete per-device encryption migration

## Import Statistics

### Most Imported Services
1. `chat_service.dart` - Used everywhere
2. `auth_service.dart` - Core dependency
3. `device_encryption_service.dart` - Active E2EE
4. `encryption_startup_service_v2.dart` - Startup

### Least Imported (Candidates for removal)
1. `encryption_service.dart` - 0 imports
2. `encryption_startup_service.dart` - 0 imports
3. `reconnect_manager.dart` - Minimal imports
4. `search_index_service.dart` - Check usage
5. `message_scroll_service.dart` - Check usage

## Cross-Module Dependencies

### Violations of Separation of Concerns
- ChatScreen imports encryption directly (should go through service)
- ChatService imports security hardening (should be separate)
- AuthService contains startup state (should be separate)

### Recommended Boundaries
```
UI Layer (Screens)
├── ChatScreen
└── ChatListScreen

Service Layer (Business Logic)
├── ChatService
├── SecureChatService
└── DeviceEncryptionService

Data Layer (Repositories)
├── MessageRepository
├── ChatRoomRepository
└── UserRepository

Infrastructure Layer (Utils)
├── RSAHelper
├── EncryptionHelper
└── SecurityHardeningService
```

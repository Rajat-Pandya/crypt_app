# Architecture Documentation

## System Overview

Crypt is built using a layered architecture pattern with clear separation of concerns:

## Layers

### 1. Presentation Layer (UI)
- **Screens**: Full-page views (ChatScreen, LoginScreen, etc.)
- **Widgets**: Reusable UI components (ChatBubble, Avatar, etc.)
- **State Management**: BLoC pattern for reactive UI updates

### 2. Business Logic Layer (Services)
- **SecureChatService**: Handles encryption/decryption
- **ChatUtilService**: Core chat operations
- **DeviceService**: Device registration and trust
- **GameService**: Multiplayer game synchronization

### 3. Data Layer (Repositories + Cache)
- **Repositories**: Abstract data access (Firestore)
- **Cache**: Hive local storage for offline support
- **Models**: Data classes with serialization

### 4. Infrastructure Layer
- **Firebase**: Authentication, Firestore, Cloud Functions
- **OneSignal**: Push notifications
- **Encryption**: Pointycastle cryptographic operations

## Data Flow

### Sending a Message

```
User Input
    ↓
[ChatScreen] captures input
    ↓
[SecureChatService] encrypts message
    - Generates AES-256 key
    - Encrypts content with AES-GCM
    - Encrypts AES key with RSA-4096
    - Computes HMAC-SHA256
    ↓
[ChatRoomRepository] saves to Firestore
    ↓
[Firestore] syncs to recipient devices
    ↓
[Cache] saves locally for offline access
```

### Receiving a Message

```
[Firestore] detects new message
    ↓
[ChatRoomRepository] streams update
    ↓
[ChatScreen] receives notification
    ↓
[SecureChatService] decrypts
    - Decrypts AES key with RSA private key
    - Decrypts content with AES-GCM
    - Verifies HMAC-SHA256
    ↓
[ChatScreen] displays plaintext
```

## Security Model

### Trust Boundaries

1. **Device Level**: Keys stored in secure hardware (Keystore/Keychain)
2. **User Level**: Authentication via Firebase Auth
3. **Message Level**: End-to-end encryption
4. **Transport Level**: TLS for Firebase communication

### Key Hierarchy

```
Root Trust: Device Hardware
    ↓
User Identity: Firebase Authentication
    ↓
Encryption Keys: RSA-4096 Key Pair
    ↓
Message Keys: AES-256 per message
    ↓
Integrity: HMAC-SHA256
```

## State Management

### BLoC Pattern

Each feature has its own BLoC:

- **ChatBloc**: Manages chat state, messages, typing indicators
- **AuthBloc**: Authentication state, user session
- **GameBloc**: Game state, moves, synchronization

### State Flow

```
Event → BLoC → Service → Repository → Firestore
                      ↓
                   Stream ← BLoC ← UI Update
```

## Caching Strategy

### Hive Cache

- **Chat Rooms**: Cached for offline access
- **Messages**: Last 100 messages per room
- **User Profiles**: Cached with TTL
- **Keys**: Cached for performance

### Cache Invalidation

- Time-based: Automatic expiry after 7 days
- Event-based: Clear on logout, key rotation
- Size-based: LRU eviction when full

## Multiplayer Architecture

### Game Synchronization

```
Player A Move
    ↓
[GameService] validates move
    ↓
[Firestore Transaction] atomic update
    ↓
Real-time sync to Player B
    ↓
[GameBloc] updates UI
```

### Conflict Resolution

- Last-write-wins with timestamp
- Turn-based locking
- State validation on each update

## Performance Considerations

### Optimizations

1. **Lazy Loading**: Messages loaded on demand
2. **Pagination**: 100 messages per query
3. **Debouncing**: Typing indicators throttled
4. **Isolates**: Encryption in background
5. **Image Caching**: Avatar images cached

### Scalability

- Firestore scales automatically
- Cache reduces Firestore reads
- BLoC prevents UI rebuild storms
- Repository pattern enables swapping backends

## Error Handling

### Strategy

1. **Network Errors**: Retry with exponential backoff
2. **Auth Errors**: Redirect to login
3. **Encryption Errors**: Mark message as failed
4. **Firestore Errors**: Log and show user-friendly message

### Recovery

- Automatic retry for transient failures
- Offline queue for failed operations
- Graceful degradation when services unavailable

---

*See [README.md](README.md) for project overview*

# Decryption Operations Audit Report

## Executive Summary

This audit identified **22 direct decryption calls** across **11 files** that bypass the centralized `DecryptQueueManager` and `DecryptMemoizationService`. Only **3 files** properly use the centralized services.

### Key Findings
- **DecryptMemoizationService is completely unused** - defined but never imported anywhere
- **Only MessageRepository and OptimizedMessageBubble** properly use DecryptQueueManager
- **ChatScreen has the most violations** with 11 direct decryption calls
- Most decryption bypasses result in **rebuild storms** and **duplicate decrypt operations**

---

## Centralized Services Status

### DecryptQueueManager (lib/services/decrypt_queue_manager.dart)
**Status: UNDERUTILIZED**
- Properly used by: `MessageRepository`, `OptimizedMessageList`, `OptimizedMessageBubble`
- **Files bypassing**: 10+
- Features that are bypassed:
  - Max 2 concurrent decrypts limit
  - FIFO queue with deduplication
  - Proper cancellation of disposed tasks
  - No build-phase decrypt scheduling

### DecryptMemoizationService (lib/services/decrypt_memoization_service.dart)
**Status: COMPLETELY UNUSED**
- Zero imports across the entire codebase
- Features completely bypassed:
  - Completed decrypt result caching
  - In-progress operation deduplication
  - Failed decrypt TTL caching
  - LRU cache eviction
  - Permanent failure tracking

---

## Direct Decryption Calls by File

### 1. lib/screens/chat_screen.dart (11 calls) ⚠️ HIGHEST VIOLATION
**All calls bypass centralized services**

| Line | Call | Context |
|------|------|---------|
| 506 | `RSAHelper.decrypt(encrypted, privateKey)` | RSA self-test |
| 984 | `RSAHelper.decrypt(aesKeyEncrypted, currentKeyFallback)` | Fallback decrypt (receiver) |
| 986 | `EncryptionHelper.decryptMessage(...)` | AES decrypt after RSA |
| 1069 | `RSAHelper.decrypt(aesKeyEncrypted, privateKey)` | Primary decrypt (receiver) |
| 1071 | `EncryptionHelper.decryptMessage(...)` | AES decrypt after RSA |
| 1186 | `RSAHelper.decrypt(aesKeySenderEncrypted, privateKey)` | Own message decrypt |
| 1188 | `EncryptionHelper.decryptMessage(...)` | AES decrypt after RSA |
| 1268 | `RSAHelper.decrypt(aesKeyReceiverEncrypted, privateKey)` | Multi-device decrypt |
| 1270 | `EncryptionHelper.decryptMessage(...)` | AES decrypt after RSA |
| 1321 | `RSAHelper.decrypt(aesKeyEncrypted, privateKey)` | Legacy decrypt |
| 1323 | `EncryptionHelper.decryptMessage(...)` | AES decrypt after RSA |

**Issues:**
- Has its own `_decryptCache` (line 86) - duplicates DecryptMemoizationService functionality
- Has its own `_decryptingInProgress` tracking (line 91) - duplicates queue functionality
- Has its own `_pendingDecrypts` (line 87) - duplicates queue deduplication
- Has manual active decrypt counting (line 98) - duplicates queue tracking

**Recommendation:** Replace all direct calls with `MessageRepository.decryptMessage()` which uses centralized queue.

---

### 2. lib/services/secure_chat_service.dart (2 calls)

| Line | Call | Context |
|------|------|---------|
| 694 | `RSAHelper.decrypt(aesKeyEncrypted, privateKey)` | AsyncDecryptManager |
| 695 | `EncryptionHelper.decryptMessage(...)` | AES decrypt |

**Issues:**
- Has its own `_decryptCache` (static map) - line ~670
- Has its own `_pendingDecrypts` (static map)
- Has its own retry logic (3 attempts) - duplicates queue functionality

**Recommendation:** Use `DecryptQueueManager` or `MessageRepository` instead.

---

### 3. lib/blocs/chat_bloc.dart (2 calls)

| Line | Call | Context |
|------|------|---------|
| 802 | `RSAHelper.decrypt(encryptedAesKeyReceiver, privateKey)` | Edit message decrypt |
| 807 | `RSAHelper.decrypt(encryptedAesKeySender, privateKey)` | Edit message decrypt (fallback) |

**Context:** Used in `DecryptForEditEvent` handler to decrypt message before editing

**Issues:**
- Decrypts for edit operations without queue management
- Could cause UI blocking during edit

**Recommendation:** Route through `MessageRepository` or use `DecryptQueueManager`.

---

### 4. lib/services/crypto_security_service.dart (2 calls)

| Line | Call | Context |
|------|------|---------|
| 702 | `EncryptionHelper.decryptMessage(ciphertext, aesKey, iv)` | decryptSecure (legacy) |
| 760 | `EncryptionHelper.decryptMessage(ciphertext, aesKey, iv)` | decryptSecure (secure) |

**Context:** Security-hardened decryption with HMAC verification

**Issues:**
- Used for secure message decryption in encryption_bloc
- Bypasses queue/memoization

**Recommendation:** This is a lower-level service - callers should use centralized services.

---

### 5. lib/services/forward_service.dart (1 call)

| Line | Call | Context |
|------|------|---------|
| 110 | `EncryptionHelper.decryptMessage(text, aesKey, iv)` | Forward message decrypt |

**Context:** Decrypts message before forwarding with attribution

**Issues:**
- No queue management for forward operations
- Could block UI during decrypt

**Recommendation:** Use `MessageRepository` for decryption.

---

### 6. lib/services/session_key_service.dart (1 call)

| Line | Call | Context |
|------|------|---------|
| 355 | `RSAHelper.decrypt(encryptedHmacKey, privateKey)` | HMAC key decrypt |

**Context:** Decrypts HMAC session key

**Issues:**
- Session key decryption bypasses queue
- Less critical (smaller payload) but still worth tracking

**Recommendation:** Lower priority - session keys are small and infrequent.

---

### 7. lib/services/device_encryption_service.dart (1 call)

| Line | Call | Context |
|------|------|---------|
| 390 | `RSAHelper.decrypt(encryptedMessage, _cachedPrivateKey)` | Device payload decrypt |

**Context:** Decrypts device-specific encrypted payloads

**Issues:**
- Device-level decryption without queue coordination

**Recommendation:** Lower priority - device payloads are typically small.

---

### 8. lib/services/game_service.dart (1 call)

| Line | Call | Context |
|------|------|---------|
| 790 | `EncryptionHelper.decryptMessage(encryptedSecret, key, iv)` | Game secret decrypt |

**Context:** Decrypts game secret for number guessing game

**Issues:**
- No queue management for game operations

**Recommendation:** Lower priority - game operations are infrequent.

---

### 9. lib/blocs/encryption_bloc.dart (1 call)

| Line | Call | Context |
|------|------|---------|
| 665 | `EncryptionHelper.decryptMessage(...)` | Legacy message decrypt |

**Context:** Fallback for legacy message format

**Issues:**
- Called from BLoC without queue coordination
- Uses `crypto_security_service.dart` for secure path

**Recommendation:** Route through centralized queue.

---

## Files Using Centralized Services ✓

### 1. lib/repositories/message_repository.dart ✓
**Properly uses DecryptQueueManager**
- Line 25: `final _decryptQueue = DecryptQueueManager()`
- Line 103-115: Uses `_decryptQueue.queueDecrypt()` for all decryption
- Has its own caching layer (lines 44-84)

**This is the correct pattern - other files should use MessageRepository.**

---

### 2. lib/widgets/optimized_message_list.dart ✓
**Properly uses DecryptQueueManager**
- Line 58: `final _decryptQueue = DecryptQueueManager()`
- Only instantiates but delegates actual decryption to `MessageRepository`

---

### 3. lib/widgets/optimized_message_bubble.dart ✓
**Properly uses DecryptQueueManager**
- Line 9: Imports `DecryptQueueManager`
- Line 137-144: Listens to `onDecryptComplete` stream
- Line 204-210: Delegates to `_repository.decryptMessage()` which uses queue

**Note:** This widget properly delegates to MessageRepository which uses the queue.

---

## Summary Statistics

| Category | Count |
|----------|-------|
| **Total Direct Decryption Calls** | 22 |
| **Files with Direct Decryption** | 11 |
| **Files Using Centralized Queue** | 3 |
| **Files Using DecryptMemoizationService** | 0 |
| **Estimated Bypass Percentage** | **85%** |

### Direct Calls by Method

| Method | Count |
|--------|-------|
| `RSAHelper.decrypt` | 12 |
| `EncryptionHelper.decryptMessage` | 10 |

### Most Problematic Files (by call count)

| Rank | File | Calls | Priority |
|------|------|-------|----------|
| 1 | chat_screen.dart | 11 | 🔴 Critical |
| 2 | secure_chat_service.dart | 2 | 🟠 High |
| 3 | chat_bloc.dart | 2 | 🟠 High |
| 4 | crypto_security_service.dart | 2 | 🟡 Medium |
| 5 | (others) | 1 each | 🟢 Low |

---

## Recommendations

### Immediate Actions (Critical)
1. **Refactor chat_screen.dart** - Replace 11 direct calls with MessageRepository
2. **Implement DecryptMemoizationService usage** - It's completely unused
3. **Audit chat_screen's custom caching** - Remove duplicate `_decryptCache` and `_decryptingInProgress`

### Short-term (High Priority)
4. **Refactor secure_chat_service.dart** - Use centralized queue
5. **Refactor chat_bloc.dart** - Route decryption through MessageRepository

### Medium-term (Medium Priority)
6. **Update crypto_security_service.dart callers** - Use queue for secure decrypts
7. **Update forward_service.dart** - Use MessageRepository

### Lower Priority
8. **Update session_key_service.dart** - HMAC key decrypt (smaller impact)
9. **Update device_encryption_service.dart** - Device payload decrypt
10. **Update game_service.dart** - Game secret decrypt

---

## Architecture Recommendations

### Option 1: Enforce MessageRepository (Recommended)
- Make `MessageRepository.decryptMessage()` the **only** public decryption API
- Remove all direct `RSAHelper.decrypt` and `EncryptionHelper.decryptMessage` calls
- Centralize all caching, queuing, and deduplication in MessageRepository

### Option 2: Create DecryptService Facade
- Create a `DecryptService` that wraps both `DecryptQueueManager` and `DecryptMemoizationService`
- Provide single entry point: `DecryptService.decryptMessage()`
- Migrate all callers to use the facade

### Option 3: Code Generation Enforcement
- Add custom lint rules to prevent direct crypto calls
- Use `// ignore:` comments for rare legitimate bypasses

---

## Security & Performance Impact

### Performance Issues from Bypasses
- **Rebuild storms**: chat_screen.dart triggers multiple simultaneous decrypts
- **Duplicate work**: Same message decrypted multiple times without memoization
- **UI blocking**: Direct calls may block main thread (despite isolate usage)
- **Memory waste**: Multiple duplicate caches (_decryptCache in 3+ files)

### Security Considerations
- No security vulnerabilities identified
- All bypasses still use proper encryption/decryption
- Main concern is resource exhaustion from duplicate operations

---

*Report generated: 2026-05-20*
*Total files analyzed: 22*
*Decryption calls found: 22 direct + 3 queued*

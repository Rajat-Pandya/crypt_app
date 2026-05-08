/// Input validation and sanitization utilities.
///
/// ── Sanitization policy for this app ─────────────────────────────────────
///
/// This app uses end-to-end encryption (E2EE).
/// Messages are encrypted before leaving the device and decrypted
/// locally — they are never interpreted as HTML by any renderer.
///
/// Flutter's Text() widget renders plain strings.
/// There is no DOM, no HTML parser, and no XSS attack surface.
///
/// Therefore:
///   • HTML-entity encoding is NEVER applied to message content
///   • sanitizeMessage() has been intentionally removed
///   • Validation (length, empty) is the only gate on message content
///
/// Sanitization IS applied to:
///   • Display names      — shown in UI, length/character restricted
///   • Search queries     — used in local filtering, length restricted
///
/// If this app ever adds a WebView that renders user content,
/// this policy must be revisited before that feature ships.
/// ──────────────────────────────────────────────────────────────────────────
class InputValidator {
  // ── Message Validation ────────────────────────────────────────────────────

  /// Validates a chat message before encryption and sending.
  ///
  /// Returns an error string if invalid, null if the message is acceptable.
  ///
  /// Does NOT modify the content — validation only.
  /// The original text is passed directly to the encryption pipeline.
  static String? validateMessage(String? text) {
    if (text == null || text.trim().isEmpty) {
      return 'Message cannot be empty';
    }
    if (text.length > 5000) {
      return 'Message too long (max 5000 characters)';
    }
    return null;
  }

  // ── Name Validation ───────────────────────────────────────────────────────

  /// Validates a display name.
  ///
  /// Names are shown in the UI directly — character restriction
  /// prevents rendering issues without needing HTML encoding.
  static String? validateName(String? name) {
    if (name == null || name.trim().isEmpty) {
      return 'Name cannot be empty';
    }
    if (name.trim().length < 2) {
      return 'Name must be at least 2 characters';
    }
    if (name.trim().length > 50) {
      return 'Name too long (max 50 characters)';
    }
    // ✅ Allowlist approach — only permit known-safe characters
    // Rejects control characters, zero-width characters, and
    // characters that could cause display layout issues
    if (!RegExp(r"^[a-zA-Z0-9\s\-_'.]+$").hasMatch(name.trim())) {
      return 'Name contains invalid characters';
    }
    return null;
  }

  // ── Email Validation ──────────────────────────────────────────────────────

  /// Validates an email address format.
  ///
  /// Does not verify deliverability — Firebase handles that.
  static String? validateEmail(String? email) {
    if (email == null || email.trim().isEmpty) {
      return 'Email cannot be empty';
    }
    final emailRegex = RegExp(
      r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
    );
    if (!emailRegex.hasMatch(email.trim())) {
      return 'Invalid email format';
    }
    return null;
  }

  // ── Search Query Sanitization ─────────────────────────────────────────────

  /// Sanitizes a local search query.
  ///
  /// Search runs against locally-decrypted strings in memory.
  /// There is no database query — no injection risk.
  /// Sanitization here is purely defensive length limiting.
  ///
  /// ── Fix from original ────────────────────────────────────────────────────
  /// Previously stripped all punctuation with [^\w\s].
  /// That prevented searching for "it's", "3:00", "v2.0" etc.
  ///
  /// Now: only enforce length limit and strip zero-width characters.
  /// The search algorithm itself handles matching safely.
  /// ─────────────────────────────────────────────────────────────────────────
  static String sanitizeSearchQuery(String query) {
    final trimmed = query
        // ✅ Remove zero-width and invisible characters
        //    These can cause search to silently not match
        .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
        .trim();

    // ✅ Length check after trim — not before
    //    Previously checked query.length (pre-trim) which was off
    //    by however many leading/trailing spaces the user had typed
    if (trimmed.length > 100) {
      return trimmed.substring(0, 100);
    }

    return trimmed;
  }

  // ── Zero-width Character Strip ────────────────────────────────────────────

  /// Removes invisible zero-width characters from any string.
  ///
  /// Used for display names and other UI strings where invisible
  /// characters could cause layout or comparison issues.
  ///
  /// Safe to call on any string — does not modify visible content.
  static String stripInvisible(String text) {
    return text.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '').trim();
  }
}

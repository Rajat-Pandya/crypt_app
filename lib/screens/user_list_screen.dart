import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../utils/avatar_utils.dart';
import '../main.dart';
import '../utils/input_validator.dart';
import 'chat_screen.dart' show ChatScreen;

class UserListScreen extends StatefulWidget {
  const UserListScreen({super.key});

  @override
  State<UserListScreen> createState() => _UserListScreenState();
}

class _UserListScreenState extends State<UserListScreen> {
  final currentUser = FirebaseAuth.instance.currentUser!;
  final _emailController = TextEditingController();

  // Result of the last search
  Map<String, dynamic>? _foundUser;

  // State flags
  bool _isSearching = false;
  String? _errorMessage;
  bool _hasSearched = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  // ── Search ─────────────────────────────────────────────────────────────────

  Future<void> _searchByEmail() async {
    debugPrint('[UserList] _searchByEmail: START');
    final email = _emailController.text.trim().toLowerCase();

    // Validate email format first
final emailErr = InputValidator.validateEmail(email);
    if (emailErr != null) {
      setState(() {
        _errorMessage = emailErr;
        debugPrint('[UserList] _searchByEmail: email validation failed — $emailErr');
        _foundUser = null;
        _hasSearched = false;
      });
      return;
    }

    // Can't add yourself
    if (email == currentUser.email?.toLowerCase()) {
      setState(() {
        _errorMessage = "That's your own email address.";
        debugPrint('[UserList] _searchByEmail: tried searching own email');
        _foundUser = null;
        _hasSearched = false;
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _errorMessage = null;
      _foundUser = null;
      _hasSearched = false;
    });

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection("users")
          .where("email", isEqualTo: email)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) {
        setState(() {
          _errorMessage = "No account found. Ask them to sign up first.";
          _foundUser = null;
          _hasSearched = true;
        });
      } else {
        final data = snapshot.docs.first.data();

        debugPrint('[UserList] Found user: uid=${data["uid"]}, hasKey=${data["publicKey"] != null}');

        setState(() {
          _foundUser = data;
          _errorMessage = null;
          _hasSearched = true;
        });
      }
    } catch (e) {
      debugPrint('[UserList] _searchByEmail: ERROR ${e.runtimeType}');
      setState(() {
        _errorMessage = "Something went wrong. Please try again.";
        _foundUser = null;
        _hasSearched = true;
      });
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  void _clearSearch() {
    setState(() {
      _emailController.clear();
      _foundUser = null;
      _errorMessage = null;
      _hasSearched = false;
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return Scaffold(
      backgroundColor: colors.screenBg,
      appBar: AppBar(
        backgroundColor: colors.appBarBg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.primaryText),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          "New Chat",
          style: TextStyle(
            color: colors.primaryText,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header card ───────────────────────────────────────────────────
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.accent.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.person_search_outlined,
                  color: colors.accent,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "Enter someone's email address to start a conversation.",
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.secondaryText,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Email input ───────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: colors.inputBg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: _errorMessage != null
                            ? Colors.red.withValues(alpha: 0.5)
                            : colors.borderColor,
                      ),
                    ),
                    child: TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.search,
                      style: TextStyle(color: colors.primaryText),
                      onSubmitted: (_) => _searchByEmail(),
                      onChanged: (_) {
                        // Clear error as user types
                        if (_errorMessage != null) {
                          setState(() => _errorMessage = null);
                        }
                      },
                      decoration: InputDecoration(
                        hintText: "Enter email address...",
                        hintStyle: TextStyle(color: colors.hintText),
                        prefixIcon: Icon(
                          Icons.email_outlined,
                          color: colors.secondaryText,
                          size: 20,
                        ),
                        suffixIcon: _emailController.text.isNotEmpty
                            ? IconButton(
                                icon: Icon(
                                  Icons.clear,
                                  color: colors.secondaryText,
                                  size: 18,
                                ),
                                onPressed: _clearSearch,
                              )
                            : null,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Search button
                GestureDetector(
                  onTap: _isSearching ? null : _searchByEmail,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _isSearching
                          ? colors.accent.withValues(alpha: 0.5)
                          : colors.accent,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: _isSearching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.search, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),

          // ── Error message ─────────────────────────────────────────────────
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, color: Colors.red, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 24),

          // ── Result ────────────────────────────────────────────────────────
          if (!_hasSearched && !_isSearching)
            Expanded(child: _buildEmptyPrompt(colors))
          else if (_isSearching)
            Expanded(
              child: Center(
                child: CircularProgressIndicator(color: colors.accent),
              ),
            )
          else if (_foundUser != null)
            _buildUserResult(context, colors, _foundUser!)
          else
            Expanded(child: _buildNotFound(colors)),
        ],
      ),
    );
  }

  // ── Empty prompt (before any search) ──────────────────────────────────────

  Widget _buildEmptyPrompt(AppColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.alternate_email,
              size: 36,
              color: colors.accent.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            "Find someone by email",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: colors.primaryText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Type an email above and tap search",
            style: TextStyle(fontSize: 13, color: colors.secondaryText),
          ),
        ],
      ),
    );
  }

  // ── Not found state ────────────────────────────────────────────────────────

  Widget _buildNotFound(AppColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_off_outlined, size: 64, color: colors.hintText),
          const SizedBox(height: 16),
          Text(
            "No account found",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: colors.secondaryText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Ask them to sign up first",
            style: TextStyle(fontSize: 13, color: colors.hintText),
          ),
        ],
      ),
    );
  }

  // ── Found user result card ─────────────────────────────────────────────────

  Widget _buildUserResult(
    BuildContext context,
    AppColors colors,
    Map<String, dynamic> userData,
  ) {
    // ✅ stripInvisible() used — correct method per input_validator.dart policy
    // sanitizeMessage() does not exist in this codebase (intentionally removed)
    // stripInvisible() removes zero-width and invisible characters from
    // Firestore display strings before rendering in UI
    final email = InputValidator.stripInvisible(
      userData["email"] as String? ?? "Unknown",
    );
    final name = InputValidator.stripInvisible(
      userData["name"] as String? ?? email.split("@")[0],
    );

    // ✅ Null-safe uid with early return — prevents crash if uid missing
    final uid = userData["uid"] as String?;
    if (uid == null || uid.trim().isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "USER FOUND",
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.green.shade600,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: colors.cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () {
                final hasKey = userData["publicKey"] != null;
                if (!hasKey) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        "This user hasn't set up encryption yet. Ask them to open the app.",
                      ),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                  return;
                }
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(receiverId: uid),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // Avatar
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: colors.accent,
                      child: Text(
                        getInitials(name),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),

                    // Name + email
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: colors.primaryText,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            email,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.secondaryText,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),

                    // Start chat button
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: colors.accent,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline,
                            color: Colors.white,
                            size: 15,
                          ),
                          SizedBox(width: 6),
                          Text(
                            "Chat",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

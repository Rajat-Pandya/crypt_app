// lib/widgets/forward_contact_list.dart
// Widget for selecting a contact to forward messages to
// Extracted from chat_screen.dart to reduce file size

import 'package:flutter/material.dart';
import '../services/forward_service.dart';

/// Widget for selecting a contact to forward messages to
/// 
/// Displays a list of chats that can be forwarded to.
/// Used in the message forwarding flow.
/// /// Usage:
/// ```dart
/// ForwardContactList(
///   currentUserId: currentUser.uid,
///   onSelect: (userId, userName) {
///     // Handle selection
///   },
/// )
/// ```
class ForwardContactList extends StatefulWidget {
  final String currentUserId;
  final Function(String userId, String userName) onSelect;

  const ForwardContactList({
    super.key,
    required this.currentUserId,
    required this.onSelect,
  });

  @override
  State<ForwardContactList> createState() => _ForwardContactListState();
}

class _ForwardContactListState extends State<ForwardContactList> {
  List<Map<String, dynamic>> _chats = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadChats();
  }

  Future<void> _loadChats() async {
    try {
      final chats = await ForwardService.getForwardableChats(widget.currentUserId);
      if (mounted) {
        setState(() {
          _chats = chats.map((c) => {
            'userId': c['otherUserId'],
            'userName': c['otherUserName'],
            'lastMessage': c['lastMessage'] ?? 'No messages',
          }).toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('ForwardContactList: ERROR loading chats: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_chats.isEmpty) {
      return const Center(
        child: Text('No chats available to forward to'),
      );
    }

    return ListView.builder(
      itemCount: _chats.length,
      itemBuilder: (context, index) {
        final chat = _chats[index];
        return ListTile(
          leading: CircleAvatar(
            child: Text(
              (chat['userName'] as String).isNotEmpty
                  ? (chat['userName'] as String)[0].toUpperCase()
                  : '?',
            ),
          ),
          title: Text(chat['userName'] as String),
          subtitle: Text(
            chat['lastMessage'] as String,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => widget.onSelect(
            chat['userId'] as String,
            chat['userName'] as String,
          ),
        );
      },
    );
  }
}

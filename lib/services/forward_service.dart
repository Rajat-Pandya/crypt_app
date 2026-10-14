import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:pointycastle/asymmetric/api.dart';
import '../cache/models/message_cache.dart';
import '../cache/models/chat_room_cache.dart';
import '../repositories/chat_room_repository.dart';
import '../services/chat_util_service.dart';
import '../services/chat_list_service.dart';
import '../services/secure_chat_service.dart';
import '../utils/rsa_helper.dart';
import '../utils/encryption.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Service for forwarding messages to other chats
/// 
/// Handles:
/// - Copying message content to new chat
/// - Re-encryption for new recipient
/// - Sending as new message with attribution
class ForwardService {
  static final _firestore = FirebaseFirestore.instance;
  
  static void _dbg(String message) {
    assert(() {
      debugPrint('[ForwardService] $message');
      return true;
    }());
  }
  
  /// Forward a message to another user
  /// 
  /// [messageIds] - IDs of messages to forward (can be multiple)
  /// [sourceRoomId] - Current chat room ID
  /// [targetUserId] - User ID to forward to
  /// [targetUserName] - Display name of target user
  /// [currentUserId] - Current user's ID
  static Future<bool> forwardMessages({
    required List<String> messageIds,
    required String sourceRoomId,
    required String targetUserId,
    required String targetUserName,
    required String currentUserId,
  }) async {
    _dbg('forwardMessages: START - forwarding ${messageIds.length} messages to $targetUserId');
    
    try {
      // Get target room ID
      final targetRoomId = ChatListService.getRoomId(currentUserId, targetUserId);
      
      // Get source messages
      final sourceRoomDoc = await _firestore
          .collection('chat_rooms')
          .doc(sourceRoomId)
          .get();
      
      if (!sourceRoomDoc.exists) {
        _dbg('forwardMessages: ERROR - source room not found');
        return false;
      }
      
      // Get receiver's public key
      final receiverDoc = await _firestore
          .collection('users')
          .doc(targetUserId)
          .get();
      
      if (!receiverDoc.exists) {
        _dbg('forwardMessages: ERROR - receiver not found');
        return false;
      }
      
      // Get messages to forward
      final messagesSnapshot = await _firestore
          .collection('chat_rooms')
          .doc(sourceRoomId)
          .collection('messages')
          .where(FieldPath.documentId, whereIn: messageIds)
          .get();
      
      final messages = messagesSnapshot.docs;
      
      // Forward each message
      for (final doc in messages) {
        final data = doc.data();
        final text = data['text'] as String? ?? '';
        
        // Get original sender name
        final senderId = data['senderId'] as String? ?? currentUserId;
        String senderName = 'Forwarded message';
        
        if (senderId != currentUserId) {
          // Get sender's name
          final senderDoc = await _firestore
              .collection('users')
              .doc(senderId)
              .get();
          if (senderDoc.exists) {
            senderName = senderDoc.data()?['name'] as String? ?? 'Someone';
          }
        }
        
        // Decrypt the message first (we need the plaintext)
        String? decryptedText;
        try {
          final aesKey = data['aesKey'] as String?;
          final iv = data['iv'] as String?;
          
          if (aesKey != null && iv != null) {
            // Decrypt using sender's key
            decryptedText = await EncryptionHelper.decryptMessage(text, aesKey, iv);
          } else {
            decryptedText = text;
          }
        } catch (e) {
          _dbg('forwardMessages: could not decrypt message, using original text');
          decryptedText = text;
        }
        
        if (decryptedText == null || decryptedText.isEmpty) {
          continue;
        }
        
        // Format with attribution
        final forwardedText = 'Forwarded from $senderName:\n\n$decryptedText';
        
        // Send to target user using SecureChatService (handles key management)
        // Get public keys for encryption
        final receiverPublicKeyResult = await ChatUtilService.loadReceiverPublicKey(targetUserId);
        final senderPublicKeyResult = await ChatUtilService.loadReceiverPublicKey(currentUserId);
        
        if (receiverPublicKeyResult == null || senderPublicKeyResult == null) {
          _dbg('forwardMessages: ERROR - could not load public keys');
          continue;
        }
        
        await SecureChatService.sendSecureMessage(
          currentUserId: currentUserId,
          receiverId: targetUserId,
          text: forwardedText,
          receiverPublicKey: receiverPublicKeyResult.publicKey,
          senderPublicKey: senderPublicKeyResult.publicKey,
          senderKeyVersion: receiverPublicKeyResult.version,
          receiverKeyVersion: senderPublicKeyResult.version,
        );
        
        _dbg('forwardMessages: forwarded message ${doc.id}');
      }
      
      _dbg('forwardMessages: SUCCESS - forwarded ${messages.length} messages');
      return true;
    } catch (e) {
      _dbg('forwardMessages: ERROR - $e');
      return false;
    }
  }
  
  /// Get list of existing chats for contact picker
  /// Returns list of maps with room info including other user's details
  static Future<List<Map<String, dynamic>>> getForwardableChats(String currentUserId) async {
    try {
      final chats = await ChatRoomRepository.getChatRooms(currentUserId);
      
      // Filter to only show chats with messages and extract other user info
      final forwardableChats = <Map<String, dynamic>>[];
      
      for (final chat in chats) {
        if (chat.lastMessageTime == null) continue;
        
        // Get other user from users list
        final otherUserId = chat.users.firstWhere(
          (u) => u != currentUserId,
          orElse: () => '',
        );
        
        if (otherUserId.isEmpty) continue;
        
        // Get other user's name from Firestore
        try {
          final userDoc = await _firestore.collection('users').doc(otherUserId).get();
          final userName = userDoc.data()?['name'] as String? ?? 'Unknown';
          
          forwardableChats.add({
            'roomId': chat.roomId,
            'otherUserId': otherUserId,
            'otherUserName': userName,
            'lastMessage': chat.lastMessage ?? 'No messages',
          });
        } catch (e) {
          _dbg('getForwardableChats: error getting user $otherUserId: $e');
        }
      }
      
      return forwardableChats;
    } catch (e) {
      _dbg('getForwardableChats: ERROR - $e');
      return [];
    }
  }
}

/// Contact picker dialog for forwarding messages
class ForwardContactPicker extends StatefulWidget {
  final List<String> selectedMessageIds;
  final String sourceRoomId;
  final String currentUserId;
  
  const ForwardContactPicker({
    super.key,
    required this.selectedMessageIds,
    required this.sourceRoomId,
    required this.currentUserId,
  });
  
  @override
  State<ForwardContactPicker> createState() => _ForwardContactPickerState();
}

class _ForwardContactPickerState extends State<ForwardContactPicker> {
  List<Map<String, dynamic>> _chats = [];
  bool _isLoading = true;
  
  @override
  void initState() {
    super.initState();
    _loadChats();
  }
  
  Future<void> _loadChats() async {
    final chats = await ForwardService.getForwardableChats(widget.currentUserId);
    if (mounted) {
      setState(() {
        _chats = chats;
        _isLoading = false;
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Forward to...'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _chats.isEmpty
                ? const Center(
                    child: Text('No chats available'),
                  )
                : ListView.builder(
                    itemCount: _chats.length,
                    itemBuilder: (context, index) {
                      final chat = _chats[index];
                      return ListTile(
                        leading: CircleAvatar(
                          child: Text((chat['otherUserName'] as String).isNotEmpty
                              ? (chat['otherUserName'] as String)[0].toUpperCase()
                              : '?'),
                        ),
                        title: Text(chat['otherUserName'] as String),
                        subtitle: Text(
                          chat['lastMessage'] as String? ?? 'No messages',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _forwardToUser(chat),
                      );
                    },
                  ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
      ],
    );
  }
  
  Future<void> _forwardToUser(Map<String, dynamic> chat) async {
    setState(() => _isLoading = true);
    
    final success = await ForwardService.forwardMessages(
      messageIds: widget.selectedMessageIds,
      sourceRoomId: widget.sourceRoomId,
      targetUserId: chat['otherUserId'] as String,
      targetUserName: chat['otherUserName'] as String,
      currentUserId: widget.currentUserId,
    );
    
    if (mounted) {
      setState(() => _isLoading = false);
      Navigator.pop(context);
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? 'Forwarded ${widget.selectedMessageIds.length} message(s)'
              : 'Failed to forward messages'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }
}

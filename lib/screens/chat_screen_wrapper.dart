import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/chat_bloc.dart';
import '../blocs/connectivity_bloc.dart';
import '../blocs/encryption_bloc.dart';
import '../blocs/game_bloc.dart';
import '../services/chat_list_service.dart';
import 'chat_screen.dart';

/// Wrapper widget that provides BLoCs for ChatScreen.
/// 
/// Usage:
///   Navigator.push(
///     context,
///     MaterialPageRoute(
///       builder: (_) => ChatScreenWrapper(receiverId: 'user123'),
///     ),
///   );
class ChatScreenWrapper extends StatelessWidget {
  final String receiverId;

  const ChatScreenWrapper({
    super.key,
    required this.receiverId,
  });

  @override
  Widget build(BuildContext context) {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';
    final roomId = ChatListService.getRoomId(currentUserId, receiverId);

    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) => ChatBloc(
            roomId: roomId,
            receiverId: receiverId,
          )..add(ChatInitialized(roomId, receiverId)),
        ),
        BlocProvider(
          create: (context) => ConnectivityBloc()
            ..add(const ConnectivityInitialized()),
        ),
        BlocProvider(
          create: (context) => EncryptionBloc()
            ..add(EncryptionInitialized(
              currentUserId: currentUserId,
              receiverId: receiverId,
            )),
        ),
        BlocProvider(
          create: (context) => GameBloc()
            ..add(GameInitialized(
              roomId: roomId,
              currentUserId: currentUserId,
            )),
        ),
      ],
      child: ChatScreen(receiverId: receiverId),
    );
  }
}

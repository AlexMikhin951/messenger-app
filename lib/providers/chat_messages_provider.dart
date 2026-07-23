import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';

import 'services_providers.dart';

@immutable
class ChatMessagesState {
  const ChatMessagesState({
    this.messages = const [],
    this.isInitialLoading = true,
  });

  final List<RecordModel> messages;
  final bool isInitialLoading;

  ChatMessagesState copyWith({
    List<RecordModel>? messages,
    bool? isInitialLoading,
  }) {
    return ChatMessagesState(
      messages: messages ?? this.messages,
      isInitialLoading: isInitialLoading ?? this.isInitialLoading,
    );
  }
}

class ChatMessagesNotifier extends Notifier<ChatMessagesState> {
  ChatMessagesNotifier(this._receiverId);

  final String _receiverId;

  String get _myId => ref.read(apiServiceProvider).pb.authStore.record?.id ?? '';

  @override
  ChatMessagesState build() {
    Future.microtask(_init);
    return const ChatMessagesState();
  }

  Future<void> _init() async {
    await loadMessages();
    await markAsRead();
    _subscribe();
  }

  Future<void> loadMessages() async {
    if (_myId.isEmpty) {
      state = state.copyWith(isInitialLoading: false);
      return;
    }

    try {
      final api = ref.read(apiServiceProvider);
      final records = await api.pb.collection('messages').getFullList(
            filter:
                '(sender = "$_myId" && receiver = "$_receiverId") || (sender = "$_receiverId" && receiver = "$_myId")',
            sort: '-created',
          );
      state = state.copyWith(messages: records, isInitialLoading: false);
    } catch (_) {
      state = state.copyWith(isInitialLoading: false);
    }
  }

  Future<void> markAsRead() async {
    if (_myId.isEmpty) return;

    try {
      final api = ref.read(apiServiceProvider);
      final unread = state.messages.where((message) {
        final type = message.getStringValue('type');
        return message.getStringValue('receiver') == _myId &&
            message.getBoolValue('is_read') == false &&
            (type == 'text' ||
                type == 'file' ||
                type == 'call_missed' ||
                type == 'call_success' ||
                type == 'call_started');
      });

      for (final message in unread) {
        await api.pb
            .collection('messages')
            .update(message.id, body: {'is_read': true});
      }
    } catch (_) {}
  }

  void _subscribe() {
    final api = ref.read(apiServiceProvider);
    api.pb.collection('messages').subscribe('*', (event) {
      if (event.record == null) return;

      final message = event.record!;
      final senderId = message.getStringValue('sender');
      final receiver = message.getStringValue('receiver');
      final type = message.getStringValue('type');

      if ((senderId == _myId && receiver == _receiverId) ||
          (senderId == _receiverId && receiver == _myId)) {
        final messages = List<RecordModel>.from(state.messages);

        if (event.action == 'create') {
          messages.insert(0, message);
          if (receiver == _myId && (type == 'text' || type == 'file')) {
            markAsRead();
          }
        } else if (event.action == 'update') {
          final index = messages.indexWhere((item) => item.id == message.id);
          if (index != -1) messages[index] = message;
        } else if (event.action == 'delete') {
          messages.removeWhere((item) => item.id == message.id);
        }

        state = state.copyWith(messages: messages);
      }
    });
  }

  Future<void> sendText({
    required String text,
    String? editingMessageId,
  }) async {
    if (text.trim().isEmpty || _myId.isEmpty) return;

    final api = ref.read(apiServiceProvider);
    if (editingMessageId != null) {
      await api.pb
          .collection('messages')
          .update(editingMessageId, body: {'content': text.trim()});
    } else {
      await api.pb.collection('messages').create(body: {
        'sender': _myId,
        'receiver': _receiverId,
        'content': text.trim(),
        'type': 'text',
        'is_read': false,
      });
    }
  }

  Future<void> deleteMessage(String messageId) async {
    await ref.read(apiServiceProvider).pb.collection('messages').delete(messageId);
  }

  Future<String?> startVideoCall() async {
    if (_myId.isEmpty) return null;

    final api = ref.read(apiServiceProvider);
    final callMsg = await api.pb.collection('messages').create(body: {
      'sender': _myId,
      'receiver': _receiverId,
      'content': 'звонок',
      'type': 'call_started',
      'is_read': false,
    });
    return callMsg.id;
  }
}

final chatMessagesProvider = NotifierProvider.family<
    ChatMessagesNotifier, ChatMessagesState, String>(
  ChatMessagesNotifier.new,
);

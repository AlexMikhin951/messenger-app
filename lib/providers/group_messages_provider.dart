import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';

import '../services/group_chat_service.dart';
import 'services_providers.dart';

@immutable
class GroupMessagesState {
  const GroupMessagesState({
    this.messages = const [],
    this.isLoading = true,
  });

  final List<RecordModel> messages;
  final bool isLoading;

  GroupMessagesState copyWith({
    List<RecordModel>? messages,
    bool? isLoading,
  }) {
    return GroupMessagesState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class GroupMessagesNotifier extends Notifier<GroupMessagesState> {
  GroupMessagesNotifier(this._groupId);

  final String _groupId;

  String get _myId =>
      ref.read(apiServiceProvider).pb.authStore.record?.id ?? '';

  GroupChatService get _service => ref.read(groupChatServiceProvider);

  @override
  GroupMessagesState build() {
    ref.onDispose(_service.unsubscribe);
    Future.microtask(_init);
    return const GroupMessagesState();
  }

  Future<void> _init() async {
    await loadHistory();
    _service.subscribe(_groupId, (record, action) {
      final messages = List<RecordModel>.from(state.messages);

      if (action == 'delete') {
        messages.removeWhere((message) => message.id == record.id);
        state = state.copyWith(messages: messages);
        return;
      }

      final index = messages.indexWhere((message) => message.id == record.id);
      if (index == -1 && action == 'create') {
        messages.insert(0, record);
        _checkAndMarkRead(record);
      } else if (index != -1) {
        messages[index] = record;
      }

      state = state.copyWith(messages: messages, isLoading: false);
    });
  }

  Future<void> loadHistory() async {
    try {
      final data = await _service.getGroupMessages(_groupId);
      state = state.copyWith(messages: data, isLoading: false);
      for (final message in data) {
        _checkAndMarkRead(message);
      }
    } catch (_) {
      state = state.copyWith(isLoading: false);
    }
  }

  void _checkAndMarkRead(RecordModel message) {
    final readBy = message.data['read_by'] ?? [];
    if (!readBy.contains(_myId)) {
      _service.markAsRead(message.id);
    }
  }

  Future<void> sendText(String content) async {
    await _service.sendText(_groupId, content);
  }

  Future<void> deleteMessage(String messageId) async {
    await ref.read(apiServiceProvider).pb.collection('group_messages').delete(messageId);
  }
}

final groupMessagesProvider = NotifierProvider.family<
    GroupMessagesNotifier, GroupMessagesState, String>(
  GroupMessagesNotifier.new,
);

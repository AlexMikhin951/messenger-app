import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services_providers.dart';

@immutable
class ContactsState {
  const ContactsState({
    this.displayUsers = const [],
    this.groups = const [],
    this.unreadUserIds = const {},
    this.unreadGroupIds = const {},
    this.localNames = const {},
    this.isLoading = true,
    this.isSearching = false,
  });

  final List<RecordModel> displayUsers;
  final List<RecordModel> groups;
  final Set<String> unreadUserIds;
  final Set<String> unreadGroupIds;
  final Map<String, String> localNames;
  final bool isLoading;
  final bool isSearching;

  ContactsState copyWith({
    List<RecordModel>? displayUsers,
    List<RecordModel>? groups,
    Set<String>? unreadUserIds,
    Set<String>? unreadGroupIds,
    Map<String, String>? localNames,
    bool? isLoading,
    bool? isSearching,
  }) {
    return ContactsState(
      displayUsers: displayUsers ?? this.displayUsers,
      groups: groups ?? this.groups,
      unreadUserIds: unreadUserIds ?? this.unreadUserIds,
      unreadGroupIds: unreadGroupIds ?? this.unreadGroupIds,
      localNames: localNames ?? this.localNames,
      isLoading: isLoading ?? this.isLoading,
      isSearching: isSearching ?? this.isSearching,
    );
  }
}

class ContactsNotifier extends Notifier<ContactsState> {
  final AudioPlayer _notificationPlayer = AudioPlayer();
  bool _subscriptionsActive = false;

  @override
  ContactsState build() {
    ref.onDispose(() {
      final api = ref.read(apiServiceProvider);
      api.pb.collection('messages').unsubscribe('*');
      api.pb.collection('group_messages').unsubscribe('*');
      _notificationPlayer.dispose();
    });
    return const ContactsState();
  }

  Future<void> initialize(BuildContext context) async {
    ref.read(signalingManagerProvider);
    await _loadLocalNames();
    await _loadRecentChats();
    _ensureSubscriptions();
  }

  void _ensureSubscriptions() {
    if (_subscriptionsActive) return;
    _subscriptionsActive = true;

    final api = ref.read(apiServiceProvider);

    api.pb.collection('messages').subscribe('*', (e) {
      final myId = api.pb.authStore.record?.id;
      if (myId == null) return;

      if (e.action == 'create') {
        final message = e.record;
        if (message == null) return;

        final senderId = message.getStringValue('sender');
        final receiverId = message.getStringValue('receiver');
        final isRead = message.getBoolValue('is_read');

        if (receiverId == myId && senderId != myId && !isRead) {
          _playNotificationSound();
          final unread = {...state.unreadUserIds, senderId};
          final isUserInList =
              state.displayUsers.any((user) => user.id == senderId);
          state = state.copyWith(unreadUserIds: unread);
          if (!isUserInList) {
            _loadRecentChats();
          }
        }
      } else if (e.action == 'update') {
        _loadRecentChats();
      }
    });

    api.pb.collection('group_messages').subscribe('*', (e) {
      final myId = api.pb.authStore.record?.id;
      if (myId == null || e.record == null) return;

      if (e.action == 'create') {
        final groupId = e.record!.getStringValue('group_id');
        final senderId = e.record!.getStringValue('sender');

        if (senderId != myId) {
          _playNotificationSound();
          state = state.copyWith(
            unreadGroupIds: {...state.unreadGroupIds, groupId},
          );
        }
      }
    });
  }

  Future<void> _playNotificationSound() async {
    try {
      await _notificationPlayer.setVolume(1.0);
      await _notificationPlayer.play(AssetSource('sounds/bel.mp3'));
    } catch (e) {
      debugPrint('Ошибка проигрывания bel.mp3: $e');
    }
  }

  Future<void> _loadLocalNames() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((key) => key.startsWith('name_'));
    final loadedNames = <String, String>{};
    for (final key in keys) {
      loadedNames[key.replaceFirst('name_', '')] = prefs.getString(key) ?? '';
    }
    state = state.copyWith(localNames: loadedNames);
  }

  Future<void> refresh() => _loadRecentChats();

  Future<void> markGroupRead(String groupId) async {
    final unread = {...state.unreadGroupIds}..remove(groupId);
    state = state.copyWith(unreadGroupIds: unread);
    await _loadRecentChats();
  }

  Future<void> renameContact(String userId, String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('name_$userId', name.trim());
    await _loadLocalNames();
  }

  Future<void> createGroup({
    required String name,
    required Set<String> memberIds,
    required String myId,
  }) async {
    final api = ref.read(apiServiceProvider);
    await api.pb.collection('groups').create(body: {
      'name': name.trim(),
      'created_by': myId,
      'members': memberIds.toList()..add(myId),
    });
    await _loadRecentChats();
  }

  Future<void> searchContact(String query) async {
    if (query.isEmpty) {
      state = state.copyWith(isSearching: false);
      await _loadRecentChats();
      return;
    }

    state = state.copyWith(isLoading: true, isSearching: true);

    try {
      final api = ref.read(apiServiceProvider);
      final records = await api.pb.collection('users').getList(
            filter: 'username ~ "$query"',
          );

      final myRecord = api.pb.authStore.record;
      final results = List<RecordModel>.from(records.items);

      if (myRecord != null && !results.any((user) => user.id == myRecord.id)) {
        if (myRecord.getStringValue('username').contains(query)) {
          results.add(myRecord);
        }
      }

      state = state.copyWith(displayUsers: results, isLoading: false);
    } catch (_) {
      state = state.copyWith(isLoading: false);
    }
  }

  void logout() {
    ref.read(apiServiceProvider).pb.authStore.clear();
  }

  Future<void> _sendNtfyCodeIfNeeded(String myId, String phone) async {
    try {
      final api = ref.read(apiServiceProvider);
      final cleanPhone = phone.replaceAll(RegExp(r'\D'), '');
      final existing = await api.pb.collection('messages').getList(
            page: 1,
            perPage: 1,
            filter:
                'sender = "$myId" && receiver = "$myId" && content ~ "family_msg_"',
          );

      if (existing.totalItems == 0) {
        await api.pb.collection('messages').create(body: {
          'sender': myId,
          'receiver': myId,
          'content': 'family_msg_$cleanPhone',
          'is_read': true,
          'type': 'text',
        });
        await api.pb.collection('messages').create(body: {
          'sender': myId,
          'receiver': myId,
          'content':
              'Это ваш уникальный ключ для уведомлений. Не удаляйте это сообщение.',
          'is_read': true,
          'type': 'text',
        });
      }
    } catch (e) {
      debugPrint('Ошибка ntfy: $e');
    }
  }

  Future<void> _loadRecentChats() async {
    final api = ref.read(apiServiceProvider);
    final myRecord = api.pb.authStore.record;
    if (myRecord == null) return;

    final myId = myRecord.id;
    final myPhone = myRecord.getStringValue('username');

    try {
      final messages = await api.pb.collection('messages').getFullList(
            sort: '-created',
            filter: 'sender = "$myId" || receiver = "$myId"',
          );

      final groups = await api.pb.collection('groups').getFullList(
            filter: 'members ~ "$myId"',
            sort: '-updated',
          );

      if (messages.isEmpty && groups.isEmpty) {
        await _sendNtfyCodeIfNeeded(myId, myPhone);
        state = state.copyWith(isLoading: false);
        return;
      }

      final userIds = <String>{myId};
      final unreadUserIds = <String>{};

      for (final message in messages) {
        final senderId = message.getStringValue('sender');
        final receiverId = message.getStringValue('receiver');

        if (receiverId == myId &&
            senderId != myId &&
            !message.getBoolValue('is_read')) {
          unreadUserIds.add(senderId);
        }
        userIds.add(senderId);
        userIds.add(receiverId);
      }

      final currentUnreadGroupIds = <String>{};
      for (final group in groups) {
        final unreadCheck = await api.pb.collection('group_messages').getList(
              page: 1,
              perPage: 1,
              filter: 'group_id = "${group.id}" && read_by !~ "$myId"',
            );
        if (unreadCheck.totalItems > 0) {
          currentUnreadGroupIds.add(group.id);
        }
      }

      if (!state.isSearching) {
        final userFilter = userIds.map((id) => 'id = "$id"').join(' || ');
        final users = userFilter.isEmpty
            ? <RecordModel>[]
            : await api.pb.collection('users').getFullList(filter: userFilter);

        users.sort((a, b) {
          if (a.id == myId) return -1;
          if (b.id == myId) return 1;
          final aHasUnread = unreadUserIds.contains(a.id);
          final bHasUnread = unreadUserIds.contains(b.id);
          if (aHasUnread && !bHasUnread) return -1;
          if (!aHasUnread && bHasUnread) return 1;
          return 0;
        });

        state = state.copyWith(
          displayUsers: users,
          groups: groups,
          unreadUserIds: unreadUserIds,
          unreadGroupIds: currentUnreadGroupIds,
          isLoading: false,
        );
      } else {
        state = state.copyWith(
          unreadUserIds: unreadUserIds,
          unreadGroupIds: currentUnreadGroupIds,
        );
      }
    } catch (e) {
      debugPrint('Ошибка загрузки чатов: $e');
      state = state.copyWith(isLoading: false);
    }
  }
}

final contactsProvider = NotifierProvider<ContactsNotifier, ContactsState>(
  ContactsNotifier.new,
);

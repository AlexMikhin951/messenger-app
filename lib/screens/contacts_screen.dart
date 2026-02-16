import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pocketbase/pocketbase.dart';
import '../services/api_service.dart';
import '../screens/group_chat_screen.dart';
import 'chat_screen.dart';
import 'auth_screen.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _searchController = TextEditingController();
  List<RecordModel> _displayUsers = [];
  // К остальным переменным в начале класса
  List<RecordModel> _groups = [];
  // В начало класса _ContactsScreenState
  Set<String> _unreadGroupIds = {};
  Map<String, String> _localNames = {};
  Set<String> _unreadUserIds =
      {}; // Сет ID пользователей, от которых есть непрочитанные
  bool _isLoading = true;
  bool _isSearching = false;
  final api = ApiService();

  @override
  void initState() {
    super.initState();
    _initialLoad();
    _subscribeToGlobalMessages();
    _subscribeToGroupMessages();
  }

  Future<void> _initialLoad() async {
    await _loadLocalNames();
    await _loadRecentChats();
  }

  void _subscribeToGlobalMessages() {
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
          if (mounted) {
            setState(() {
              _unreadUserIds.add(senderId);
              bool isUserInList = _displayUsers.any((u) => u.id == senderId);
              if (!isUserInList) {
                _loadRecentChats();
              }
            });
          }
        }
      } else if (e.action == 'update') {
        _loadRecentChats();
      }
    });
  }

  Future<void> _loadLocalNames() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('name_'));
    final Map<String, String> loadedNames = {};
    for (var key in keys) {
      loadedNames[key.replaceFirst('name_', '')] = prefs.getString(key) ?? '';
    }
    setState(() => _localNames = loadedNames);
  }

  Future<void> _sendNtfyCodeIfNeeded(String myId, String phone) async {
    try {
      final cleanPhone = phone.replaceAll(RegExp(r'\D'), '');
      final existing = await api.pb.collection('messages').getList(
            page: 1,
            perPage: 1,
            filter:
                'sender = "$myId" && receiver = "$myId" && content ~ "family_msg_"',
          );

      if (existing.totalItems == 0) {
        // Создаем техническую запись для ntfy
        await api.pb.collection('messages').create(body: {
          "sender": myId,
          "receiver": myId,
          "content": "family_msg_$cleanPhone",
          "is_read": true,
          "type": "text",
        });
        // Информационное сообщение для пользователя
        await api.pb.collection('messages').create(body: {
          "sender": myId,
          "receiver": myId,
          "content":
              "Это ваш уникальный ключ для уведомлений. Не удаляйте это сообщение.",
          "is_read": true,
          "type": "text",
        });
      }
    } catch (e) {
      debugPrint("Ошибка ntfy: $e");
    }
  }

  Future<void> _loadRecentChats() async {
    final myRecord = api.pb.authStore.record;
    if (myRecord == null) return;
    final myId = myRecord.id;
    final myPhone = myRecord.getStringValue('username');

    try {
      // 1. Загружаем личные сообщения
      final messages = await api.pb.collection('messages').getFullList(
            sort: '-created',
            filter: 'sender = "$myId" || receiver = "$myId"',
          );

      // 2. Загружаем группы
      final groups = await api.pb.collection('groups').getFullList(
            filter: 'members ~ "$myId"',
            sort: '-updated',
          );

      // Если всё пусто, отправляем код ntfy (ваша логика)
      if (messages.isEmpty && groups.isEmpty) {
        await _sendNtfyCodeIfNeeded(myId, myPhone);
        _loadRecentChats();
        return;
      }

      // --- ОБРАБОТКА ЛИЧНЫХ СООБЩЕНИЙ ---
      Set<String> userIds = {myId};
      Set<String> unreadUserIds = {};

      for (var m in messages) {
        String s = m.getStringValue('sender');
        String r = m.getStringValue('receiver');
        // Если я получатель, сообщение от другого и оно не прочитано
        if (r == myId && s != myId && !m.getBoolValue('is_read')) {
          unreadUserIds.add(s);
        }
        userIds.add(s);
        userIds.add(r);
      }

      // --- ОБРАБОТКА ГРУППОВЫХ СООБЩЕНИЙ (Непрочитанные) ---
      Set<String> currentUnreadGroupIds = {};

      for (var group in groups) {
        // Делаем запрос: есть ли в этой группе сообщения,
        // где в списке read_by НЕТ моего ID и отправитель НЕ я.
        // Оператор !~ означает "не содержит"
        final unreadCheck = await api.pb.collection('group_messages').getList(
              page: 1,
              perPage: 1,
              filter:
                  'group_id = "${group.id}" && sender != "$myId" && read_by !~ "$myId"',
            );

        if (unreadCheck.totalItems > 0) {
          currentUnreadGroupIds.add(group.id);
        }
      }

      // --- ОБНОВЛЕНИЕ СПИСКА ПОЛЬЗОВАТЕЛЕЙ ---
      if (!_isSearching) {
        String userFilter = userIds.map((id) => 'id = "$id"').join(' || ');
        final users =
            await api.pb.collection('users').getFullList(filter: userFilter);

        // Сортировка (сначала я, потом те, у кого непрочитанные)
        users.sort((a, b) {
          if (a.id == myId) return -1;
          if (b.id == myId) return 1;
          final aHasUnread = unreadUserIds.contains(a.id);
          final bHasUnread = unreadUserIds.contains(b.id);
          if (aHasUnread && !bHasUnread) return -1;
          if (!aHasUnread && bHasUnread) return 1;
          return 0;
        });

        if (mounted) {
          setState(() {
            _displayUsers = users;
            _groups = groups;
            _unreadUserIds = unreadUserIds;
            _unreadGroupIds = currentUnreadGroupIds; // Новая переменная
            _isLoading = false;
          });
        }
      } else {
        // Если мы в режиме поиска, обновляем только статусы непрочитанных
        if (mounted) {
          setState(() {
            _unreadUserIds = unreadUserIds;
            _unreadGroupIds = currentUnreadGroupIds;
          });
        }
      }
    } catch (e) {
      debugPrint("Ошибка загрузки чатов: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _subscribeToGroupMessages() {
    api.pb.collection('group_messages').subscribe('*', (e) {
      final myId = api.pb.authStore.record?.id;
      if (myId == null || e.record == null) return;

      if (e.action == 'create') {
        final groupId = e.record!.getStringValue('group_id');
        final List<dynamic> readBy = e.record!.data['read_by'] ?? [];

        // Если меня нет в списке прочитавших — значит сообщение новое для меня
        if (!readBy.contains(myId)) {
          if (mounted) {
            setState(() {
              _unreadGroupIds.add(groupId);
            });
          }
        }
      }
    });
  }

  Future<void> _createGroupDialog() async {
    final nameController = TextEditingController();
    final myId = api.pb.authStore.record?.id;
    // Список пользователей для выбора (кроме себя)
    List<RecordModel> availableUsers =
        _displayUsers.where((u) => u.id != myId).toList();
    Set<String> selectedIds = {};

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text("Новая группа"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment
                .start, // Выравнивание заголовка по левому краю
            children: [
              // Поле ввода названия группы
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: "Название группы",
                  prefixIcon: const Icon(Icons.edit),
                  filled: true,
                  fillColor: Colors.grey.shade50,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                "Выберите участников:",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              // Список контактов для выбора
              Container(
                height: 250, // Немного увеличил высоту для удобства
                width: double.maxFinite,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade200),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: availableUsers.length,
                  itemBuilder: (c, i) {
                    final user = availableUsers[i];
                    // Получаем имя из локальных имен или из PocketBase
                    final displayName =
                        _localNames[user.id] ?? user.getStringValue('name');
                    final phone = user.getStringValue('username');

                    return CheckboxListTile(
                      activeColor: Colors.blueAccent,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12),
                      title: Text(
                        displayName.isEmpty ? "Без имени" : displayName,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(phone),
                      secondary: CircleAvatar(
                        radius: 18,
                        backgroundColor: Colors.grey.shade200,
                        child: const Icon(Icons.person,
                            size: 20, color: Colors.grey),
                      ),
                      value: selectedIds.contains(user.id),
                      onChanged: (v) {
                        // Важно: setDialogState обновляет состояние внутри диалога
                        setDialogState(() {
                          if (v == true) {
                            selectedIds.add(user.id);
                          } else {
                            selectedIds.remove(user.id);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Отмена")),
            ElevatedButton(
              onPressed: () async {
                if (nameController.text.isEmpty || selectedIds.isEmpty) return;
                await api.pb.collection('groups').create(body: {
                  "name": nameController.text.trim(),
                  "created_by": myId,
                  "members": selectedIds.toList()..add(myId!),
                });
                Navigator.pop(ctx);
                _loadRecentChats();
              },
              child: const Text("Создать"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupTile(RecordModel group) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: InkWell(
        onTap: () {
          // Здесь будет переход в ChatScreen для группы
          // Убедитесь, что ваш ChatScreen умеет работать с группой или создайте GroupChatScreen
        },
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.05), // Легкий фон для групп
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.blue.shade100),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: Colors.blue.shade400,
                child: const Icon(Icons.groups, color: Colors.white),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.getStringValue('name'),
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Групповой чат",
                      style:
                          TextStyle(fontSize: 14, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _searchContact(String query) async {
    if (query.isEmpty) {
      setState(() => _isSearching = false);
      _loadRecentChats();
      return;
    }

    setState(() {
      _isLoading = true;
      _isSearching = true;
    });

    try {
      final records = await api.pb.collection('users').getList(
            filter: 'username ~ "$query"',
          );

      final myRecord = api.pb.authStore.record;
      List<RecordModel> results = records.items;

      // Добавляем себя в поиск, если подходим
      if (myRecord != null && !results.any((u) => u.id == myRecord.id)) {
        if (myRecord.getStringValue('username').contains(query)) {
          results.add(myRecord);
        }
      }

      if (mounted) {
        setState(() {
          _displayUsers = results;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _logout() {
    api.pb.authStore.clear();
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (context) => const AuthScreen()));
  }

  void _showRenameDialog(String userId, String currentName) {
    final controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Имя контакта"),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Отмена")),
          ElevatedButton(
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('name_$userId', controller.text.trim());
              await _loadLocalNames();
              Navigator.pop(context);
            },
            child: const Text("Сохранить"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final myId = api.pb.authStore.record?.id;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        title: Text(_isSearching ? "Поиск" : "Чаты",
            style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
              icon: const Icon(Icons.group_add),
              onPressed: _createGroupDialog), // Новая кнопка
          IconButton(
              icon: const Icon(Icons.refresh), onPressed: _loadRecentChats),
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              controller: _searchController,
              onChanged: _searchContact,
              decoration: InputDecoration(
                hintText: "Найти по номеру...",
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.grey.shade100,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(30),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _displayUsers.isEmpty
                      ? Center(
                          child: Text(_isSearching
                              ? "Никого не нашли"
                              : "У вас пока нет активных чатов."))
                      : ListView.builder(
                          padding: const EdgeInsets.only(top: 8),
                          // Общее количество элементов: группы + пользователи
                          itemCount: _groups.length + _displayUsers.length,
                          itemBuilder: (context, index) {
                            // --- 1. ЛОГИКА ДЛЯ ГРУПП (отображаются зеленым) ---
                            // Внутри ListView.builder, в секции логики для групп:
                            if (index < _groups.length) {
                              final group = _groups[index];
                              final groupName = group.getStringValue('name');
                              final bool hasUnreadGroup = _unreadGroupIds
                                  .contains(group.id); // Проверка

                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 6),
                                child: InkWell(
                                  onTap: () async {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => GroupChatScreen(
                                          groupId: group.id,
                                          groupName: groupName,
                                        ),
                                      ),
                                    );
                                    // После возврата из чата сбрасываем локально и обновляем
                                    setState(
                                        () => _unreadGroupIds.remove(group.id));
                                    _loadRecentChats();
                                  },
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 300),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      // Если есть непрочитанные — делаем фон как у личных чатов (синеватым или зеленым)
                                      color: hasUnreadGroup
                                          ? Colors.green.withOpacity(0.15)
                                          : Colors.green.withOpacity(0.05),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: hasUnreadGroup
                                            ? Colors.green.shade400
                                            : Colors.green.shade100,
                                        width: hasUnreadGroup ? 2 : 1,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Stack(
                                          children: [
                                            CircleAvatar(
                                              radius: 28,
                                              backgroundColor:
                                                  Colors.green.shade400,
                                              child: const Icon(Icons.groups,
                                                  color: Colors.white),
                                            ),
                                            if (hasUnreadGroup)
                                              Positioned(
                                                right: 0,
                                                top: 0,
                                                child: Container(
                                                  width: 14,
                                                  height: 14,
                                                  decoration: BoxDecoration(
                                                    color: Colors
                                                        .orange, // Оранжевый индикатор для групп
                                                    shape: BoxShape.circle,
                                                    border: Border.all(
                                                        color: Colors.white,
                                                        width: 2),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                groupName,
                                                style: TextStyle(
                                                  fontSize: 17,
                                                  fontWeight: hasUnreadGroup
                                                      ? FontWeight.bold
                                                      : FontWeight.bold,
                                                ),
                                              ),
                                              Text(
                                                hasUnreadGroup
                                                    ? "Новое сообщение!"
                                                    : "${group.getListValue('members').length} участников",
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  color: hasUnreadGroup
                                                      ? Colors.green.shade900
                                                      : Colors.green.shade800,
                                                  fontWeight: hasUnreadGroup
                                                      ? FontWeight.w600
                                                      : FontWeight.normal,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (hasUnreadGroup)
                                          const Icon(Icons.mark_chat_unread,
                                              color: Colors.green),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            }

                            // --- 2. ЛОГИКА ДЛЯ ПОЛЬЗОВАТЕЛЕЙ (после групп) ---
                            // Вычисляем индекс пользователя, вычитая количество групп
                            final userIndex = index - _groups.length;
                            final user = _displayUsers[userIndex];

                            final bool isItMe = user.id == myId;
                            final displayName = isItMe
                                ? "Избранное (Заметки)"
                                : (_localNames[user.id] ??
                                    user.getStringValue('name'));

                            final hasUnread = _unreadUserIds.contains(user.id);

                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 6),
                              child: InkWell(
                                onTap: () async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (context) =>
                                            ChatScreen(receiver: user)),
                                  );
                                  _loadRecentChats();
                                },
                                onLongPress: isItMe
                                    ? null
                                    : () =>
                                        _showRenameDialog(user.id, displayName),
                                borderRadius: BorderRadius.circular(20),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 300),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: hasUnread
                                        ? Colors.blue.withOpacity(0.08)
                                        : Colors.grey.shade100,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: hasUnread
                                          ? Colors.blue.shade300
                                          : Colors.transparent,
                                      width: 1.5,
                                    ),
                                    boxShadow: hasUnread
                                        ? [
                                            BoxShadow(
                                                color: Colors.blue
                                                    .withOpacity(0.1),
                                                blurRadius: 8,
                                                offset: const Offset(0, 4))
                                          ]
                                        : [],
                                  ),
                                  child: Row(
                                    children: [
                                      Stack(
                                        children: [
                                          CircleAvatar(
                                            radius: 28,
                                            backgroundColor: isItMe
                                                ? Colors.amber.shade100
                                                : (hasUnread
                                                    ? Colors.blue.shade100
                                                    : Colors.grey.shade300),
                                            child: Icon(
                                              isItMe
                                                  ? Icons.bookmark
                                                  : Icons.person,
                                              color: isItMe
                                                  ? Colors.amber.shade800
                                                  : Colors.black54,
                                            ),
                                          ),
                                          if (hasUnread)
                                            Positioned(
                                              right: 0,
                                              top: 0,
                                              child: Container(
                                                width: 14,
                                                height: 14,
                                                decoration: BoxDecoration(
                                                  color: Colors.blueAccent,
                                                  shape: BoxShape.circle,
                                                  border: Border.all(
                                                      color: Colors.white,
                                                      width: 2),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              displayName,
                                              style: TextStyle(
                                                fontSize: 17,
                                                fontWeight: hasUnread
                                                    ? FontWeight.bold
                                                    : FontWeight.w600,
                                                color: hasUnread
                                                    ? Colors.blue.shade900
                                                    : Colors.black87,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              isItMe
                                                  ? "Личное пространство"
                                                  : user.getStringValue(
                                                      'username'),
                                              style: TextStyle(
                                                  fontSize: 14,
                                                  color: hasUnread
                                                      ? Colors.blue.shade700
                                                      : Colors.grey.shade600),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (hasUnread)
                                        const Icon(Icons.mark_chat_unread,
                                            size: 18, color: Colors.blueAccent),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        )),
        ],
      ),
    );
  }

  @override
  void dispose() {
    api.pb.collection('messages').unsubscribe('*');
    _searchController.dispose();
    api.pb.collection('group_messages').unsubscribe('*');
    super.dispose();
  }
}

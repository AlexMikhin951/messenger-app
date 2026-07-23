import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';

import '../providers/contacts_provider.dart';
import '../providers/services_providers.dart';
import '../providers/signaling_session_provider.dart';
import 'auth_screen.dart';
import 'chat_screen.dart';
import 'group_chat_screen.dart';

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      ref.read(signalingSessionProvider.notifier).startOnContactsOpen(context);
      await ref.read(contactsProvider.notifier).initialize(context);
    });
  }

  Future<void> _createGroupDialog() async {
    final contacts = ref.read(contactsProvider);
    final api = ref.read(apiServiceProvider);
    final myId = api.pb.authStore.record?.id;
    if (myId == null) return;

    final nameController = TextEditingController();
    final availableUsers =
        contacts.displayUsers.where((user) => user.id != myId).toList();
    final selectedIds = <String>{};

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Новая группа'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Название группы',
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
                'Выберите участников:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Container(
                height: 250,
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
                    final displayName = contacts.localNames[user.id] ??
                        user.getStringValue('name');
                    final phone = user.getStringValue('username');

                    return CheckboxListTile(
                      activeColor: Colors.blueAccent,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                      title: Text(
                        displayName.isEmpty ? 'Без имени' : displayName,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(phone),
                      secondary: CircleAvatar(
                        radius: 18,
                        backgroundColor: Colors.grey.shade200,
                        child: const Icon(Icons.person, size: 20, color: Colors.grey),
                      ),
                      value: selectedIds.contains(user.id),
                      onChanged: (value) {
                        setDialogState(() {
                          if (value == true) {
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
              child: const Text('Отмена'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (nameController.text.isEmpty || selectedIds.isEmpty) return;
                await ref.read(contactsProvider.notifier).createGroup(
                      name: nameController.text,
                      memberIds: selectedIds,
                      myId: myId,
                    );
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Создать'),
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameDialog(String userId, String currentName) {
    final controller = TextEditingController(text: currentName);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Имя контакта'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () async {
              await ref
                  .read(contactsProvider.notifier)
                  .renameContact(userId, controller.text);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  void _logout() {
    ref.read(contactsProvider.notifier).logout();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const AuthScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contacts = ref.watch(contactsProvider);
    final api = ref.read(apiServiceProvider);
    final myId = api.pb.authStore.record?.id;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        title: Text(
          contacts.isSearching ? 'Поиск' : 'Чаты',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add),
            onPressed: _createGroupDialog,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(contactsProvider.notifier).refresh(),
          ),
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                controller: _searchController,
                onChanged: (query) =>
                    ref.read(contactsProvider.notifier).searchContact(query),
                decoration: InputDecoration(
                  hintText: 'Найти по номеру...',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(30),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: contacts.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : contacts.displayUsers.isEmpty && contacts.groups.isEmpty
                      ? Center(
                          child: Text(
                            contacts.isSearching
                                ? 'Никого не нашли'
                                : 'У вас пока нет активных чатов.',
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(top: 8),
                          itemCount:
                              contacts.groups.length + contacts.displayUsers.length,
                          itemBuilder: (context, index) {
                            if (index < contacts.groups.length) {
                              return _GroupTile(
                                group: contacts.groups[index],
                                hasUnread: contacts.unreadGroupIds
                                    .contains(contacts.groups[index].id),
                                onTap: () async {
                                  final group = contacts.groups[index];
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => GroupChatScreen(
                                        groupId: group.id,
                                        groupName: group.getStringValue('name'),
                                      ),
                                    ),
                                  );
                                  await ref
                                      .read(contactsProvider.notifier)
                                      .markGroupRead(group.id);
                                },
                              );
                            }

                            final userIndex = index - contacts.groups.length;
                            final user = contacts.displayUsers[userIndex];
                            final isItMe = user.id == myId;
                            final displayName = isItMe
                                ? 'Избранное (Заметки)'
                                : (contacts.localNames[user.id] ??
                                    user.getStringValue('name'));
                            final hasUnread =
                                contacts.unreadUserIds.contains(user.id);

                            return _UserTile(
                              user: user,
                              displayName: displayName,
                              isItMe: isItMe,
                              hasUnread: hasUnread,
                              onTap: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        ChatScreen(receiver: user),
                                  ),
                                );
                                await ref.read(contactsProvider.notifier).refresh();
                              },
                              onLongPress: isItMe
                                  ? null
                                  : () => _showRenameDialog(user.id, displayName),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({
    required this.group,
    required this.hasUnread,
    required this.onTap,
  });

  final RecordModel group;
  final bool hasUnread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final groupName = group.getStringValue('name');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: hasUnread
                ? Colors.green.withOpacity(0.15)
                : Colors.green.withOpacity(0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: hasUnread ? Colors.green.shade400 : Colors.green.shade100,
              width: hasUnread ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Stack(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: Colors.green.shade400,
                    child: const Icon(Icons.groups, color: Colors.white),
                  ),
                  if (hasUnread)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: Colors.orange,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      groupName,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hasUnread
                          ? 'Новое сообщение!'
                          : '${group.getListValue('members').length} участников',
                      style: TextStyle(
                        fontSize: 14,
                        color: hasUnread
                            ? Colors.green.shade900
                            : Colors.green.shade800,
                        fontWeight:
                            hasUnread ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
              if (hasUnread)
                const Icon(Icons.mark_chat_unread, color: Colors.green),
            ],
          ),
        ),
      ),
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({
    required this.user,
    required this.displayName,
    required this.isItMe,
    required this.hasUnread,
    required this.onTap,
    this.onLongPress,
  });

  final RecordModel user;
  final String displayName;
  final bool isItMe;
  final bool hasUnread;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
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
              color: hasUnread ? Colors.blue.shade300 : Colors.transparent,
              width: 1.5,
            ),
            boxShadow: hasUnread
                ? [
                    BoxShadow(
                      color: Colors.blue.withOpacity(0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
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
                      isItMe ? Icons.bookmark : Icons.person,
                      color: isItMe ? Colors.amber.shade800 : Colors.black54,
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
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight:
                            hasUnread ? FontWeight.bold : FontWeight.w600,
                        color: hasUnread ? Colors.blue.shade900 : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isItMe
                          ? 'Личное пространство'
                          : user.getStringValue('username'),
                      style: TextStyle(
                        fontSize: 14,
                        color: hasUnread
                            ? Colors.blue.shade700
                            : Colors.grey.shade600,
                      ),
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
  }
}

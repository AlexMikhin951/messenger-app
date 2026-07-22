import 'package:flutter/material.dart';

import '../demo_data.dart';
import 'chat_screen.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _searchController = TextEditingController();
  String _query = '';
  final List<DemoGroup> _demoGroups = List.of(DemoData.groups);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  List<DemoContact> get _filteredPeople {
    if (_query.isEmpty) return DemoData.people;
    return DemoData.people
        .where((c) =>
            c.name.toLowerCase().contains(_query) ||
            c.phone.contains(_query))
        .toList();
  }

  void _createGroupDialog() {
    final nameController = TextEditingController();
    final selected = <String>{};

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Новая группа'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    hintText: 'Название группы',
                    prefixIcon: const Icon(Icons.edit),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 16),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Выберите участников:', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 180,
                  child: ListView(
                    children: DemoData.people.map((user) {
                      return CheckboxListTile(
                        title: Text(user.name),
                        subtitle: Text(user.phone),
                        value: selected.contains(user.id),
                        onChanged: (v) {
                          setDialogState(() {
                            if (v == true) {
                              selected.add(user.id);
                            } else {
                              selected.remove(user.id);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
            ElevatedButton(
              onPressed: () {
                if (nameController.text.isEmpty || selected.isEmpty) return;
                setState(() {
                  _demoGroups.insert(
                    0,
                    DemoGroup(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                      name: nameController.text.trim(),
                      lastMessage: 'Группа создана',
                      members: selected.length + 1,
                    ),
                  );
                });
                Navigator.pop(ctx);
              },
              child: const Text('Создать'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Family Messenger'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(text: 'Контакты'),
            Tab(text: 'Группы'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createGroupDialog,
        child: const Icon(Icons.group_add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v.toLowerCase()),
              decoration: InputDecoration(
                hintText: 'Поиск контактов',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                ListView.separated(
                  itemCount: _filteredPeople.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey.shade200),
                  itemBuilder: (context, index) {
                    final contact = _filteredPeople[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.blue.shade100,
                        child: Text(contact.name.characters.first),
                      ),
                      title: Text(contact.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(contact.lastMessage, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(contact.lastMessageTime, style: const TextStyle(fontSize: 12)),
                          if (contact.unread > 0)
                            Container(
                              margin: const EdgeInsets.only(top: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade700,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text('${contact.unread}', style: const TextStyle(color: Colors.white, fontSize: 11)),
                            ),
                        ],
                      ),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => ChatScreen(contact: contact)),
                        );
                      },
                    );
                  },
                ),
                ListView.separated(
                  itemCount: _demoGroups.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey.shade200),
                  itemBuilder: (context, index) {
                    final group = _demoGroups[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.green.shade100,
                        child: const Icon(Icons.groups, color: Colors.green),
                      ),
                      title: Text(group.name),
                      subtitle: Text(group.lastMessage),
                      trailing: Text('${group.members} чел.'),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

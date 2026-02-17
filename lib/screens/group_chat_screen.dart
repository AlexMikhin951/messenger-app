import 'dart:io'; // Для Platform
import 'package:flutter/foundation.dart'; // Для kIsWeb
import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/group_chat_service.dart';
import '../services/api_service.dart';
import 'group_call_screen.dart'; // <--- Убедись, что импорт правильный

class GroupChatScreen extends StatefulWidget {
  final String groupId;
  final String groupName;

  const GroupChatScreen({
    super.key,
    required this.groupId,
    required this.groupName,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _service = GroupChatService();
  final _msgController = TextEditingController();
  final List<RecordModel> _messages = [];
  final Map<String, bool> _downloadingFiles = {};
  bool _isLoading = true;
  late String _myId;
  late String _myName;

  @override
  void initState() {
    super.initState();
    final user = _service.api.pb.authStore.record;
    _myId = user?.id ?? '';
    _myName = user?.getStringValue('name') ?? 'Участник';
    _initChat();
  }

  Future<void> _initChat() async {
    await _loadHistory();
    // Подписываемся на новые сообщения
    _service.subscribe(widget.groupId, (record) {
      if (mounted) {
        setState(() {
          final index = _messages.indexWhere((m) => m.id == record.id);
          if (index == -1) {
            _messages.insert(0, record);
            _checkAndMarkRead(record);
          } else {
            _messages[index] = record;
          }
        });
      }
    });
  }

  Future<void> _loadHistory() async {
    try {
      final data = await _service.getGroupMessages(widget.groupId);
      if (mounted) {
        setState(() {
          _messages.clear();
          _messages.addAll(data);
          _isLoading = false;
        });
        for (var m in data) {
          _checkAndMarkRead(m);
        }
      }
    } catch (e) {
      debugPrint("Ошибка загрузки истории: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _checkAndMarkRead(RecordModel m) {
    final List<dynamic> readBy = m.data['read_by'] ?? [];
    if (!readBy.contains(_myId)) {
      _service.markAsRead(m.id);
    }
  }

  // --- ЛОГИКА ЗВОНКА ---
  Future<void> _onJoinVideoCall() async {
    // 1. Создаем запись в БД о звонке, чтобы другие видели "Групповой звонок"
    try {
      // ПРИМЕЧАНИЕ: Я использую поле 'group', так как это групповой чат.
      // Если у тебя поле называется по-другому (например, conversation), замени его здесь.
      await _service.api.pb.collection('messages').create(body: {
        "content": "📞 Начал групповой звонок",
        "sender": _myId,
        "group": widget.groupId, // ID текущей группы
        "type": "call_success", // Тип сообщения (для иконки звонка)
        "is_read": true,
      });
    } catch (e) {
      debugPrint("Ошибка при создании записи о звонке: $e");
      // Не блокируем переход, если ошибка только в создании сообщения
    }

    // 2. Переходим на экран видеосвязи
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GroupCallScreen(
          roomName: widget.groupId, // ID Группы = ID Комнаты
          identity: _myId, // Мой ID (теперь параметр существует!)
          userName: _myName, // Мое имя
        ),
      ),
    );
  }
  // ---------------------

  Future<void> _onSendText() async {
    if (_msgController.text.trim().isEmpty) return;
    final text = _msgController.text.trim();
    _msgController.clear();
    try {
      await _service.sendText(widget.groupId, text);
    } catch (e) {
      debugPrint("Ошибка отправки текста: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Ошибка отправки")),
        );
      }
    }
  }

  Future<void> _onPickFile() async {
    try {
      FilePickerResult? result =
          await FilePicker.platform.pickFiles(withData: true);

      if (result != null) {
        final file = result.files.single;
        await _service.sendFile(widget.groupId,
            path: kIsWeb ? null : file.path,
            bytes: file.bytes,
            filename: file.name);
      }
    } catch (e) {
      debugPrint("Ошибка выбора файла: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Ошибка отправки файла: $e")),
        );
      }
    }
  }

  Future<void> _handleFileTap(RecordModel m) async {
    final String attachmentName = m.getStringValue('attachment');
    if (attachmentName.isEmpty) return;

    setState(() => _downloadingFiles[m.id] = true);
    try {
      final fileUrl =
          _service.api.pb.files.getUrl(m, attachmentName).toString();
      final uri = Uri.parse(fileUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint("Ошибка открытия файла: $e");
    } finally {
      if (mounted) setState(() => _downloadingFiles.remove(m.id));
    }
  }

  @override
  void dispose() {
    _service.unsubscribe();
    _msgController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FB),
      appBar: AppBar(
        elevation: 1,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.groupName,
                style: const TextStyle(fontSize: 16, color: Colors.white)),
            const Text("Групповой чат",
                style: TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        backgroundColor: Colors.blueAccent,
        iconTheme: const IconThemeData(color: Colors.white),
        // КНОПКА ВИДЕОЗВОНКА
        actions: [
          IconButton(
            onPressed: _onJoinVideoCall,
            icon: const Icon(Icons.videocam_rounded, size: 28),
            tooltip: "Войти в видеочат",
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) =>
                        _renderMessage(_messages[index]),
                  ),
          ),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _renderMessage(RecordModel m) {
    final String type = m.getStringValue('type', 'text');
    final bool isMe = m.getStringValue('sender') == _myId;
    final String content = m.getStringValue('content');

    // Если это сообщение о звонке - показываем красивую плашку
    if (type == 'call_missed' || type == 'call_success') {
      return _buildSystemMessage(type, content);
    }

    return _buildBubble(m, isMe, type, content);
  }

  Widget _buildSystemMessage(String type, String content) {
    final isSuccess = type == 'call_success';
    return GestureDetector(
      // При нажатии на сообщение о звонке тоже можно присоединиться
      onTap: _onJoinVideoCall,
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
              color: isSuccess
                  ? Colors.green.withOpacity(0.1)
                  : Colors.red.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: isSuccess
                      ? Colors.green.withOpacity(0.3)
                      : Colors.red.withOpacity(0.3))),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam,
                  size: 16, color: isSuccess ? Colors.green : Colors.red),
              const SizedBox(width: 8),
              Text(content,
                  style: TextStyle(
                      fontSize: 12,
                      color: isSuccess ? Colors.green[800] : Colors.red[800],
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBubble(RecordModel m, bool isMe, String type, String content) {
    final bool isDownloading = _downloadingFiles[m.id] ?? false;

    final senderData = m.expand['sender']?[0];
    final senderName = senderData?.getStringValue('name') ?? "Участник";

    final List<dynamic> readBy = m.data['read_by'] ?? [];
    final readCount = readBy.length > 1 ? readBy.length - 1 : 0;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (!isMe)
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 2),
              child: Text(senderName,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.blueGrey)),
            ),
          GestureDetector(
            onTap: type == 'file' ? () => _handleFileTap(m) : null,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 2),
              padding: const EdgeInsets.all(12),
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.75),
              decoration: BoxDecoration(
                color: isMe ? Colors.blueAccent : Colors.white,
                borderRadius: BorderRadius.circular(18).copyWith(
                  bottomRight: isMe ? const Radius.circular(2) : null,
                  bottomLeft: !isMe ? const Radius.circular(2) : null,
                ),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 5,
                      offset: const Offset(0, 2))
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (type == 'file')
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isDownloading)
                          const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                        else
                          Icon(Icons.description,
                              color: isMe ? Colors.white : Colors.blueAccent),
                        const SizedBox(width: 8),
                        Flexible(
                            child: Text(content,
                                style: TextStyle(
                                    color: isMe ? Colors.white : Colors.black87,
                                    decoration: TextDecoration.underline))),
                      ],
                    )
                  else
                    Text(content,
                        style: TextStyle(
                            color: isMe ? Colors.white : Colors.black87,
                            fontSize: 15)),
                  const SizedBox(height: 2),
                  if (isMe)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (readCount > 0)
                          Text("$readCount",
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.white70)),
                        const SizedBox(width: 2),
                        Icon(
                          readCount > 0 ? Icons.done_all : Icons.done,
                          size: 14,
                          color: readCount > 0
                              ? Colors.lightBlueAccent
                              : Colors.white60,
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)]),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
                icon: const Icon(Icons.attach_file, color: Colors.blueAccent),
                onPressed: _onPickFile),
            Expanded(
              child: TextField(
                controller: _msgController,
                decoration: InputDecoration(
                  hintText: "Ваше сообщение...",
                  filled: true,
                  fillColor: const Color(0xFFF0F2F5),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                onSubmitted: (_) => _onSendText(),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _onSendText,
              child: const CircleAvatar(
                backgroundColor: Colors.blueAccent,
                child: Icon(Icons.send, color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

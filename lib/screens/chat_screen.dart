import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';
import 'video_call_screen.dart';

class ChatScreen extends StatefulWidget {
  final RecordModel receiver;
  const ChatScreen({super.key, required this.receiver});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _msgController = TextEditingController();
  final List<RecordModel> _messages = [];
  final api = ApiService();
  late String _myId;
  bool _isInitialLoading = true;

  // Карта для хранения статуса загрузки файлов по ID сообщения
  final Map<String, bool> _downloadingFiles = {};

  @override
  void initState() {
    super.initState();
    _myId = api.pb.authStore.record!.id;
    _initChat();
  }

  Future<void> _initChat() async {
    await _loadMessages();
    await _markAsRead(); // Помечаем как прочитанные при входе
    _subscribeToMessages();
  }

  // --- ЛОГИКА ПРОЧТЕНИЯ ---

  Future<void> _markAsRead() async {
    try {
      final unread = _messages.where((m) {
        final type = m.getStringValue('type');
        return m.getStringValue('receiver') == _myId &&
            m.getBoolValue('is_read') == false &&
            // Читаем тексты, файлы и ПРОПУЩЕННЫЕ звонки
            (type == 'text' || type == 'file' || type == 'call_missed');
      }).toList();

      if (unread.isEmpty) return;

      for (var m in unread) {
        await api.pb
            .collection('messages')
            .update(m.id, body: {"is_read": true});
      }
    } catch (e) {
      debugPrint("Ошибка markAsRead: $e");
    }
  }

  // --- ЛОГИКА СООБЩЕНИЙ И ФАЙЛОВ ---

  Future<void> _loadMessages() async {
    try {
      final records = await api.pb.collection('messages').getFullList(
            filter:
                '(sender = "$_myId" && receiver = "${widget.receiver.id}") || '
                '(sender = "${widget.receiver.id}" && receiver = "$_myId")',
            sort: '-created',
          );
      if (mounted) {
        setState(() {
          _messages.clear();
          _messages.addAll(records);
          _isInitialLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isInitialLoading = false);
    }
  }

  void _subscribeToMessages() {
    api.pb.collection('messages').subscribe('*', (e) {
      if (e.record != null) {
        final m = e.record!;
        final senderId = m.getStringValue('sender');
        final receiverId = m.getStringValue('receiver');
        final type = m.getStringValue('type'); // Получаем тип сообщения

        // Проверяем, относится ли сообщение к этому конкретному чату
        if ((senderId == _myId && receiverId == widget.receiver.id) ||
            (senderId == widget.receiver.id && receiverId == _myId)) {
          if (mounted) {
            setState(() {
              if (e.action == 'create') {
                _messages.insert(0, m);

                // ЛОГИКА АВТО-ПРОЧТЕНИЯ:
                // Если я получатель и это обычный контент (текст/файл),
                // помечаем прочитанным сразу, так как экран чата открыт.
                // Если это звонок (call_success), НЕ вызываем _markAsRead,
                // чтобы is_read оставался false и система поняла, что это новый вызов.
                if (receiverId == _myId && (type == 'text' || type == 'file')) {
                  _markAsRead();
                }
              } else if (e.action == 'update') {
                final index = _messages.indexWhere((el) => el.id == m.id);
                if (index != -1) {
                  _messages[index] = m;
                }

                // Если сообщение обновилось (например, стало "call_missed")
                // и мы находимся в этом чате, можно вызвать прочтение,
                // чтобы сразу убрать индикатор нового сообщения.
                if (receiverId == _myId && type == 'call_missed') {
                  _markAsRead();
                }
              }
            });
          }
        }
      }
    });
  }

  Future<void> _sendMessage() async {
    if (_msgController.text.trim().isEmpty) return;
    final text = _msgController.text.trim();
    _msgController.clear();
    try {
      await api.pb.collection('messages').create(body: {
        "sender": _myId,
        "receiver": widget.receiver.id,
        "content": text,
        "type": "text",
        "is_read": false,
      });
    } catch (e) {
      debugPrint("Ошибка отправки: $e");
    }
  }

  Future<void> _pickAndSendFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result != null && result.files.single.path != null) {
      final file = result.files.single;
      try {
        await api.pb.collection('messages').create(
          body: {
            "sender": _myId,
            "receiver": widget.receiver.id,
            "content": file.name,
            "type": "file",
            "is_read": false,
          },
          files: [await http.MultipartFile.fromPath('attachment', file.path!)],
        );
      } catch (e) {
        debugPrint("Ошибка отправки файла: $e");
      }
    }
  }

  Future<void> _handleFileTap(RecordModel m) async {
    final String attachmentName = m.getStringValue('attachment');
    if (attachmentName.isEmpty) return;
    setState(() => _downloadingFiles[m.id] = true);
    try {
      final fileUrl = api.pb.files.getUrl(m, attachmentName).toString();
      final uri = Uri.parse(fileUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint("Ошибка при работе с файлом: $e");
    } finally {
      if (mounted) {
        setState(() => _downloadingFiles.remove(m.id));
      }
    }
  }

  void _startVideoCall() async {
    try {
      final callMsg = await api.pb.collection('messages').create(body: {
        "sender": _myId,
        "receiver": widget.receiver.id,
        "content": "Входящий видеозвонок...",
        "type": "call_success",
        "is_read":
            true, // СТАВИМ TRUE: вызов считается "просмотренным" по умолчанию
      });

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => VideoCallScreen(
            receiverId: widget.receiver.id,
            isIncoming: false,
            messageId: callMsg.id,
          ),
        ),
      );
    } catch (e) {
      debugPrint("Не удалось начать звонок: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(widget.receiver.getStringValue('name')),
        actions: [
          IconButton(
            icon: const Icon(Icons.videocam_rounded, size: 28),
            onPressed: _startVideoCall,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _isInitialLoading
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

    if (type == 'call_missed' || type == 'call_success') {
      return _buildSystemMessage(type, content);
    }
    return _buildMessageBubble(m, isMe, type, content);
  }

  Widget _buildSystemMessage(String type, String content) {
    bool isMissed = type == 'call_missed';
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
            color: isMissed
                ? Colors.red.withOpacity(0.05)
                : Colors.green.withOpacity(0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: isMissed
                    ? Colors.red.withOpacity(0.2)
                    : Colors.green.withOpacity(0.2))),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(isMissed ? Icons.call_missed : Icons.call_made,
                size: 16, color: isMissed ? Colors.red : Colors.green),
            const SizedBox(width: 8),
            Text(content,
                style: TextStyle(
                    fontSize: 13,
                    color:
                        isMissed ? Colors.red.shade700 : Colors.green.shade700,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(
      RecordModel m, bool isMe, String type, String content) {
    final bool isDownloading = _downloadingFiles[m.id] ?? false;
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: type == 'file' ? () => _handleFileTap(m) : null,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(12),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75),
          decoration: BoxDecoration(
            color: isMe ? Colors.blue.shade600 : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(16),
          ),
          child: type == 'file'
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isDownloading)
                      const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                    else
                      Icon(Icons.insert_drive_file,
                          color: isMe ? Colors.white : Colors.blue),
                    const SizedBox(width: 8),
                    Flexible(
                        child: Text(content,
                            style: TextStyle(
                                color: isMe ? Colors.white : Colors.black87,
                                decoration: TextDecoration.underline))),
                  ],
                )
              : Text(content,
                  style: TextStyle(
                      color: isMe ? Colors.white : Colors.black87,
                      fontSize: 16)),
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Colors.grey.shade200))),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
                icon: const Icon(Icons.add_circle_outline,
                    color: Colors.blue, size: 28),
                onPressed: _pickAndSendFile),
            Expanded(
              child: TextField(
                controller: _msgController,
                decoration: InputDecoration(
                  hintText: "Сообщение...",
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(25),
                      borderSide: BorderSide.none),
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
                icon: const Icon(Icons.send, color: Colors.blue),
                onPressed: _sendMessage),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    api.pb.collection('messages').unsubscribe('*');
    _msgController.dispose();
    super.dispose();
  }
}

import 'dart:io'; // Для Platform
import 'package:flutter/foundation.dart'; // Для kIsWeb
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

  final Map<String, bool> _downloadingFiles = {};

  @override
  void initState() {
    super.initState();
    _myId = api.pb.authStore.record?.id ?? "";
    if (_myId.isNotEmpty) {
      _initChat();
    } else {
      debugPrint("Ошибка: Пользователь не авторизован");
      setState(() => _isInitialLoading = false);
    }
  }

  Future<void> _initChat() async {
    await _loadMessages();
    await _markAsRead();
    _subscribeToMessages();
  }

  Future<void> _markAsRead() async {
    try {
      final unread = _messages.where((m) {
        final type = m.getStringValue('type');
        return m.getStringValue('receiver') == _myId &&
            m.getBoolValue('is_read') == false &&
            (type == 'text' ||
                type == 'file' ||
                type == 'call_missed' ||
                type == 'call_success');
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
      debugPrint("Ошибка загрузки сообщений: $e");
      if (mounted) setState(() => _isInitialLoading = false);
    }
  }

  void _subscribeToMessages() {
    api.pb.collection('messages').subscribe('*', (e) {
      if (e.record != null) {
        final m = e.record!;
        final senderId = m.getStringValue('sender');
        final receiverId = m.getStringValue('receiver');
        final type = m.getStringValue('type');

        if ((senderId == _myId && receiverId == widget.receiver.id) ||
            (senderId == widget.receiver.id && receiverId == _myId)) {
          if (mounted) {
            setState(() {
              if (e.action == 'create') {
                _messages.insert(0, m);
                if (receiverId == _myId && (type == 'text' || type == 'file')) {
                  _markAsRead();
                }
              } else if (e.action == 'update') {
                final index = _messages.indexWhere((el) => el.id == m.id);
                if (index != -1) {
                  _messages[index] = m;
                }
                if (receiverId == _myId &&
                    (type == 'call_missed' || type == 'call_success')) {
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
    FilePickerResult? result =
        await FilePicker.platform.pickFiles(withData: true);
    if (result != null) {
      final fileObj = result.files.single;
      setState(() => _isInitialLoading = true);
      try {
        http.MultipartFile multipartFile;
        if (kIsWeb) {
          if (fileObj.bytes == null)
            throw Exception("Не удалось прочитать файл");
          multipartFile = http.MultipartFile.fromBytes(
              'attachment', fileObj.bytes!,
              filename: fileObj.name);
        } else {
          if (fileObj.path == null) return;
          multipartFile = await http.MultipartFile.fromPath(
              'attachment', fileObj.path!,
              filename: fileObj.name);
        }
        await api.pb.collection('messages').create(
          body: {
            "sender": _myId,
            "receiver": widget.receiver.id,
            "content": fileObj.name,
            "type": "file",
            "is_read": false,
          },
          files: [multipartFile],
        );
      } catch (e) {
        debugPrint("Ошибка отправки файла: $e");
      } finally {
        if (mounted) setState(() => _isInitialLoading = false);
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
      if (mounted) setState(() => _downloadingFiles.remove(m.id));
    }
  }

  void _startVideoCall() async {
    if (_myId.isEmpty) return;
    String? createdMessageId;
    try {
      final callMsg = await api.pb.collection('messages').create(body: {
        "sender": _myId,
        "receiver": widget.receiver.id,
        "content": "📞 Исходящий видеозвонок...",
        "type": "call_success",
        "is_read": true,
      });
      createdMessageId = callMsg.id;
    } catch (e) {
      debugPrint("Ошибка создания звонка: $e");
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VideoCallScreen(
          receiverId: widget.receiver.id,
          isIncoming: false,
          messageId: createdMessageId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FB),
      appBar: AppBar(
        elevation: 2,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        title: Row(
          children: [
            CircleAvatar(
              backgroundColor: Colors.blue.shade100,
              child:
                  Text(widget.receiver.getStringValue('name')[0].toUpperCase()),
            ),
            const SizedBox(width: 12),
            Text(widget.receiver.getStringValue('name'),
                style: const TextStyle(fontSize: 18)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.videocam_rounded,
                color: Colors.blue, size: 28),
            onPressed: _startVideoCall,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _isInitialLoading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 16),
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
    if (type == 'call_missed' || type == 'call_success') {
      return _buildSystemMessage(m);
    }
    return _buildMessageBubble(m);
  }

  Widget _buildSystemMessage(RecordModel m) {
    final String type = m.getStringValue('type');
    final String content = m.getStringValue('content');
    final bool isMissed = type == 'call_missed';

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          // Цвет звонка: красный для пропущенного, зеленый для успешного
          color: isMissed
              ? Colors.red.withOpacity(0.1)
              : Colors.green.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: isMissed
                  ? Colors.red.withOpacity(0.2)
                  : Colors.green.withOpacity(0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isMissed ? Icons.call_missed : Icons.call_made,
              size: 16,
              color: isMissed ? Colors.red : Colors.green,
            ),
            const SizedBox(width: 8),
            Text(
              content,
              style: TextStyle(
                fontSize: 13,
                color: isMissed ? Colors.red.shade700 : Colors.green.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(RecordModel m) {
    final bool isMe = m.getStringValue('sender') == _myId;
    final String type = m.getStringValue('type');
    final String content = m.getStringValue('content');
    final bool isRead = m.getBoolValue('is_read');
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
            color: isMe ? Colors.blue.shade600 : Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isMe ? 16 : 0),
              bottomRight: Radius.circular(isMe ? 0 : 16),
            ),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 4,
                  offset: const Offset(0, 2)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
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
                      Icon(Icons.insert_drive_file,
                          color: isMe ? Colors.white : Colors.blue),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(content,
                          style: TextStyle(
                              color: isMe ? Colors.white : Colors.black87,
                              decoration: TextDecoration.underline)),
                    ),
                  ],
                )
              else
                Text(content,
                    style: TextStyle(
                        color: isMe ? Colors.white : Colors.black87,
                        fontSize: 16)),

              // Индикатор прочтения (только для моих сообщений)
              if (isMe)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Icon(
                    isRead ? Icons.done_all : Icons.done,
                    size: 16,
                    color: isRead ? Colors.lightBlueAccent : Colors.white70,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, -2))
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.add_circle_outline,
                  color: Colors.blue, size: 28),
              onPressed: _pickAndSendFile,
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(24)),
                child: TextField(
                  controller: _msgController,
                  decoration: const InputDecoration(
                      hintText: "Сообщение...", border: InputBorder.none),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            CircleAvatar(
              backgroundColor: Colors.blue,
              child: IconButton(
                icon: const Icon(Icons.send, color: Colors.white, size: 20),
                onPressed: _sendMessage,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    try {
      api.pb.collection('messages').unsubscribe('*');
    } catch (_) {}
    _msgController.dispose();
    super.dispose();
  }
}

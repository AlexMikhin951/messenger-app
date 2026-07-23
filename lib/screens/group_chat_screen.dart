import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

// Пакеты для медиа и сохранения
import 'package:file_saver/file_saver.dart';
import 'package:record/record.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart'; // Вернули плеер для видео, как в личном чате

import '../providers/chat_composer_provider.dart';
import '../providers/group_messages_provider.dart';
import '../providers/services_providers.dart';
import 'group_call_screen.dart';

enum AttachmentType { image, video, audio, document }

class GroupChatScreen extends ConsumerStatefulWidget {
  final String groupId;
  final String groupName;

  const GroupChatScreen({
    super.key,
    required this.groupId,
    required this.groupName,
  });

  @override
  ConsumerState<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends ConsumerState<GroupChatScreen> {
  String get _composerKey => 'group_${widget.groupId}';

  ChatComposerNotifier get _composer =>
      ref.read(chatComposerProvider(_composerKey).notifier);

  ChatComposerState get _composerState =>
      ref.watch(chatComposerProvider(_composerKey));

  GroupChatService get _service => ref.read(groupChatServiceProvider);
  final _msgController = TextEditingController();
  late String _myId;
  late String _myName;

  final AudioPlayer _keyboardSoundPlayer = AudioPlayer();
  final AudioPlayer _messageSoundPlayer = AudioPlayer();
  final AudioPlayer _previewAudioPlayer = AudioPlayer();


  late final AudioRecorder _audioRecorder;

  @override
  void initState() {
    super.initState();
    final user = _service.api.pb.authStore.record;
    _myId = user?.id ?? '';
    _myName = user?.getStringValue('name') ?? 'Участник';
    if (_myName.isEmpty)
      _myName = user?.getStringValue('username') ?? 'Участник';

    _messageSoundPlayer.setVolume(0.7);
    _audioRecorder = AudioRecorder();

    _previewAudioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        _composer.setPlayingPreview(state == PlayerState.playing);
      }
    });
  }

  Future<void> _playKeyboardSound() async {
    try {
      await _keyboardSoundPlayer.setVolume(0.1);
      await _keyboardSoundPlayer.play(AssetSource('sounds/keyboardtap.mp3'));
    } catch (_) {}
  }

  Future<void> _playMessageSound() async {
    try {
      await _messageSoundPlayer.setVolume(0.7);
      await _messageSoundPlayer.play(AssetSource('sounds/mes.mp3'));
    } catch (e) {
      debugPrint("Ошибка звука: $e");
    }
  }


  Future<void> _startOrJoinCall({String? existingMessageId}) async {
    String? messageIdToPass = existingMessageId;

    if (messageIdToPass == null) {
      try {
        final activeCalls = await _service.api.pb
            .collection('group_messages')
            .getList(
              filter: 'group_id = "${widget.groupId}" && type = "call_active"',
              perPage: 1,
            );

        if (activeCalls.items.isNotEmpty) {
          messageIdToPass = activeCalls.items.first.id;
        } else {
          final callMessage =
              await _service.api.pb.collection('group_messages').create(body: {
            "content": "$_myName начал(а) голосовой чат",
            "sender": _myId,
            "group_id": widget.groupId,
            "type": "call_active",
            "read_by": [_myId],
          });
          messageIdToPass = callMessage.id;
        }
      } catch (e) {
        // Выводим ошибку в консоль
        debugPrint("🚨 Ошибка при попытке начать звонок: $e");

        // Показываем ошибку пользователю
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Не удалось начать звонок. Проверьте консоль."),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
    }

    if (!mounted) return;
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (context) => GroupCallScreen(
                  roomName: widget.groupId,
                  identity: _myId,
                  userName: _myName,
                  messageId:
                      messageIdToPass!, // Используем !, так как уверены, что он не null здесь
                )));
  }

  // --- ОТПРАВКА И РЕДАКТИРОВАНИЕ ТЕКСТА ---
  Future<void> _onSendText() async {
    if (_msgController.text.trim().isEmpty) return;

    HapticFeedback.mediumImpact();
    _playMessageSound();

    final text = _msgController.text.trim();
    _msgController.clear();

    try {
      if (_composerState.editingMessageId != null) {
        await _service.api.pb.collection('group_messages').update(
              _composerState.editingMessageId!,
              body: {'content': text},
            );
        _composer.clearEditing();
      } else {
        await ref
            .read(groupMessagesProvider(widget.groupId).notifier)
            .sendText(text);
      }
    } catch (e) {
      debugPrint('Ошибка отправки текста: $e');
    }
  }

  Future<void> _deleteMessage(String id) async {
    try {
      await ref
          .read(groupMessagesProvider(widget.groupId).notifier)
          .deleteMessage(id);
    } catch (e) {
      debugPrint('Ошибка удаления: $e');
    }
  }

  Future<void> _toggleRecording() async {
    if (_composerState.isRecording) {
      try {
        final path = await _audioRecorder.stop();
        _composer.setRecording(false, filePath: path);
        HapticFeedback.lightImpact();
      } catch (_) {}
    } else {
      try {
        if (await _audioRecorder.hasPermission()) {
          final dir = await getTemporaryDirectory();
          final filePath =
              '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
          await _audioRecorder.start(
              const RecordConfig(encoder: AudioEncoder.aacLc),
              path: filePath);
          _composer.setRecording(true);
          HapticFeedback.lightImpact();
        }
      } catch (_) {}
    }
  }

  Future<void> _deleteRecording() async {
    await _previewAudioPlayer.stop();
    _composer.setRecording(false);
    _composer.setPlayingPreview(false);
  }

  Future<void> _togglePreview() async {
    if (_composerState.recordedFilePath == null) return;
    if (_composerState.isPlayingPreview) {
      await _previewAudioPlayer.pause();
    } else {
      await _previewAudioPlayer
          .play(DeviceFileSource(_composerState.recordedFilePath!));
    }
  }

  Future<void> _sendRecordedVoice() async {
    if (_composerState.recordedFilePath == null) return;
    final path = _composerState.recordedFilePath!;
    await _deleteRecording();
    await _sendFileToServer(path, 'Голосовое_сообщение.m4a', isPath: true);
  }

  Future<void> _pickAndSendFile() async {
    FilePickerResult? result =
        await FilePicker.platform.pickFiles(withData: kIsWeb);
    if (result != null) {
      final file = result.files.single;
      if (kIsWeb) {
        if (file.bytes != null)
          _sendFileToServer(file.bytes, file.name, isPath: false);
      } else {
        if (file.path != null)
          _sendFileToServer(file.path, file.name, isPath: true);
      }
    }
  }

  Future<void> _sendFileToServer(dynamic fileData, String fileName,
      {required bool isPath}) async {
    _composer.setUploading(true);
    try {
      http.MultipartFile multipartFile;
      if (isPath) {
        multipartFile = await http.MultipartFile.fromPath(
            'attachment', fileData as String,
            filename: fileName.split('/').last);
      } else {
        multipartFile = http.MultipartFile.fromBytes(
            'attachment', fileData as Uint8List,
            filename: fileName);
      }

      HapticFeedback.mediumImpact();
      _playMessageSound();

      await _service.api.pb.collection('group_messages').create(
        body: {
          "sender": _myId,
          "group_id": widget.groupId,
          "content": fileName,
          "type": "file",
          "read_by": [_myId], // Убрали is_read, используем массив
        },
        files: [multipartFile],
      );
    } catch (e) {
      debugPrint("Ошибка отправки файла: $e");
    } finally {
      if (mounted) _composer.setUploading(false);
    }
  }

  Future<void> _downloadAndSaveFile(RecordModel m) async {
    final String attachmentName = m.getStringValue('attachment');
    if (attachmentName.isEmpty) return;

    if (kIsWeb) {
      final fileUrl =
          _service.api.pb.files.getUrl(m, attachmentName).toString();
      await launchUrl(Uri.parse(fileUrl));
      return;
    }

    _composer.setDownloading(m.id, true);

    try {
      final fileUrl =
          _service.api.pb.files.getUrl(m, attachmentName).toString();
      final client = _service.api.pb.httpClientFactory();
      final response = await client.get(Uri.parse(fileUrl));

      if (response.statusCode == 200) {
        String ext = attachmentName.split('.').last;
        String nameWithoutExt =
            attachmentName.substring(0, attachmentName.lastIndexOf('.'));

        String? savedPath = await FileSaver.instance.saveAs(
          name: nameWithoutExt,
          bytes: response.bodyBytes,
          ext: ext,
          mimeType: MimeType.other,
        );

        if (savedPath != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text("Файл успешно сохранен!"),
              backgroundColor: Colors.green));
        }
      }
      client.close();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Ошибка сохранения"), backgroundColor: Colors.red));
    } finally {
      if (mounted) _composer.setDownloading(m.id, false);
    }
  }

  AttachmentType _getAttachmentType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext))
      return AttachmentType.image;
    if (['mp4', 'mov', 'avi', 'mkv'].contains(ext))
      return AttachmentType
          .video; // Вернули видео, так как у нас есть безопасный плеер
    if (['mp3', 'm4a', 'wav', 'ogg', 'aac'].contains(ext))
      return AttachmentType.audio;
    return AttachmentType.document;
  }

  // --- МЕНЮ СООБЩЕНИЯ (Telegram Style) ---
  void _showMessageOptions(RecordModel m, String type, String content) {
    final isMe = m.getStringValue('sender') == _myId;

    // Проверка прочитанности (если в read_by никого нет, кроме нас)
    final List<dynamic> readBy = m.data['read_by'] ?? [];

    // Если в массиве только мы (длина 1) или он вообще пустой, значит еще никто не читал
    final bool canEditOrDelete = isMe &&
        (readBy.isEmpty || (readBy.length == 1 && readBy.contains(_myId)));

    showModalBottomSheet(
        context: context,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (context) => SafeArea(
              child: Wrap(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text("Действия",
                        style: TextStyle(
                            color: Colors.grey.shade600,
                            fontWeight: FontWeight.bold)),
                  ),
                  if (type == 'text' || type == 'file')
                    ListTile(
                      leading: const Icon(Icons.copy, color: Colors.blueAccent),
                      title: const Text('Копировать текст'),
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: content));
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Скопировано')));
                      },
                    ),
                  if (type == 'text' && canEditOrDelete)
                    ListTile(
                      leading: const Icon(Icons.edit, color: Colors.green),
                      title: const Text('Изменить'),
                      onTap: () {
                        Navigator.pop(context);
                        _composer.startEditing(m.id);
                        _msgController.text = content;
                      },
                    ),
                  if (type == 'file')
                    ListTile(
                      leading:
                          const Icon(Icons.download, color: Colors.blueAccent),
                      title: const Text('Скачать файл'),
                      onTap: () {
                        Navigator.pop(context);
                        _downloadAndSaveFile(m);
                      },
                    ),
                  if (canEditOrDelete)
                    ListTile(
                      leading: const Icon(Icons.delete, color: Colors.red),
                      title: const Text('Удалить',
                          style: TextStyle(color: Colors.red)),
                      onTap: () {
                        Navigator.pop(context);
                        _deleteMessage(m.id);
                      },
                    ),
                  const SizedBox(height: 10),
                ],
              ),
            ));
  }

  void _openImageFullScreen(String imageUrl) {
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => FullScreenImageViewer(imageUrl: imageUrl)));
  }

  @override
  void dispose() {
    _msgController.dispose();
    _keyboardSoundPlayer.dispose();
    _messageSoundPlayer.dispose();
    _previewAudioPlayer.dispose();
    _audioRecorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groupState = ref.watch(groupMessagesProvider(widget.groupId));
    final composer = _composerState;

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
        actions: [
          IconButton(
              onPressed: () => _startOrJoinCall(),
              icon: const Icon(Icons.videocam_rounded, size: 28)),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: groupState.isLoading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(16),
                    itemCount: groupState.messages.length,
                    itemBuilder: (context, index) =>
                        _renderMessage(groupState.messages[index]),
                  ),
          ),
          if (_composerState.isUploading)
            const LinearProgressIndicator(
                minHeight: 3, color: Colors.blueAccent),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _renderMessage(RecordModel m) {
    final String type = m.getStringValue('type', 'text');
    final bool isMe = m.getStringValue('sender') == _myId;
    final String content = m.getStringValue('content');

    if (type == 'call_active' || type == 'call_ended')
      return _buildCallCard(m, type, content);

    return _buildBubble(m, isMe, type, content);
  }

  Widget _buildCallCard(RecordModel m, String type, String content) {
    final isActive = type == 'call_active';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: isActive ? Colors.green.shade400 : Colors.grey.shade300,
            width: isActive ? 2 : 1),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 3))
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: isActive
                        ? Colors.green.withOpacity(0.15)
                        : Colors.grey.withOpacity(0.15),
                    shape: BoxShape.circle),
                child: Icon(isActive ? Icons.videocam : Icons.videocam_off,
                    color: isActive ? Colors.green : Colors.grey, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(content,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    const SizedBox(height: 4),
                    Text(
                        isActive
                            ? "Голосовой чат активен"
                            : "Голосовой чат завершён",
                        style: TextStyle(
                            color: isActive
                                ? Colors.green.shade700
                                : Colors.grey.shade600,
                            fontSize: 13)),
                  ],
                ),
              )
            ],
          ),
          if (isActive) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                onPressed: () => _startOrJoinCall(existingMessageId: m.id),
                icon: const Icon(Icons.call),
                label: const Text("Присоединиться",
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            )
          ]
        ],
      ),
    );
  }

  Widget _buildBubble(RecordModel m, bool isMe, String type, String content) {
    final senderData = m.expand['sender']?[0];
    final senderName = senderData?.getStringValue('name') ?? "Участник";

    final List<dynamic> readBy = m.data['read_by'] ?? [];
    // Считаем прочитавших, не учитывая себя
    int readCount = readBy.where((id) => id != _myId).length;

    final String attachment = m.getStringValue('attachment');

    Widget bubbleContent;

    if (type == 'file' && attachment.isNotEmpty) {
      final fileUrl = _service.api.pb.files.getUrl(m, attachment).toString();
      final attType = _getAttachmentType(attachment);

      Widget wrapWithAction(Widget child) {
        return GestureDetector(
          onLongPress: () => _showMessageOptions(m, type, content),
          onSecondaryTap: () =>
              _showMessageOptions(m, type, content), // Правый клик
          child: child,
        );
      }

      switch (attType) {
        case AttachmentType.image:
          bubbleContent = wrapWithAction(
            GestureDetector(
              onTap: () => _openImageFullScreen(fileUrl),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: Image.network(fileUrl, fit: BoxFit.cover)),
              ),
            ),
          );
          break;
        case AttachmentType.video:
          bubbleContent = wrapWithAction(GroupInlineVideoPlayer(
              videoUrl: fileUrl, onDownload: () => _downloadAndSaveFile(m)));
          break;
        case AttachmentType.audio:
          bubbleContent = wrapWithAction(
              GroupInlineAudioPlayer(audioUrl: fileUrl, isMe: isMe));
          break;
        case AttachmentType.document:
          final isDownloading = _composerState.downloadingFiles[m.id] ?? false;
          bubbleContent = InkWell(
            onTap: () => _downloadAndSaveFile(m),
            onLongPress: () => _showMessageOptions(m, type, content),
            onSecondaryTap: () => _showMessageOptions(m, type, content),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: isMe ? Colors.blue.shade700 : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(8)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  isDownloading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Icon(Icons.insert_drive_file,
                          color: isMe ? Colors.white : Colors.blueAccent,
                          size: 30),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(content,
                        style: TextStyle(
                            color: isMe ? Colors.white : Colors.black87,
                            fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.download,
                      color: isMe ? Colors.white70 : Colors.blueGrey, size: 20),
                ],
              ),
            ),
          );
          break;
      }
    } else {
      bubbleContent = Text(content,
          style: TextStyle(
              color: isMe ? Colors.white : Colors.black87, fontSize: 15));
    }

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
                        color: Colors.blueGrey))),
          GestureDetector(
            onLongPress: () => _showMessageOptions(m, type, content),
            onSecondaryTap: () => _showMessageOptions(m, type, content),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 2),
              padding: const EdgeInsets.all(12),
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.75),
              decoration: BoxDecoration(
                color: isMe ? Colors.blueAccent : Colors.white,
                borderRadius: BorderRadius.circular(18).copyWith(
                    bottomRight: isMe ? const Radius.circular(2) : null,
                    bottomLeft: !isMe ? const Radius.circular(2) : null),
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
                  bubbleContent,
                  const SizedBox(height: 2),
                  if (isMe)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_composerState.editingMessageId == m.id)
                          const Icon(Icons.edit, size: 12, color: Colors.white54),
                        if (_composerState.editingMessageId == m.id) const SizedBox(width: 4),
                        if (readCount > 0)
                          Text("$readCount",
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.white70)),
                        const SizedBox(width: 2),
                        Icon(readCount > 0 ? Icons.done_all : Icons.done,
                            size: 14,
                            color: readCount > 0
                                ? Colors.lightBlueAccent
                                : Colors.white60),
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
      decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)]),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_composerState.editingMessageId != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: Colors.blue.shade50,
                child: Row(
                  children: [
                    const Icon(Icons.edit, color: Colors.blueAccent, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                        child: Text("Редактирование сообщения",
                            style: TextStyle(
                                color: Colors.blueAccent,
                                fontWeight: FontWeight.bold))),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.blueAccent),
                      onPressed: () {
                        setState(() {
                          _composer.clearEditing();
                          _msgController.clear();
                        });
                      },
                    )
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: _composerState.recordedFilePath != null
                  ? _buildPreviewAudioPanel()
                  : Row(
                      children: [
                        IconButton(
                            icon: const Icon(Icons.attach_file,
                                color: Colors.blueAccent),
                            onPressed: _pickAndSendFile),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            decoration: BoxDecoration(
                                color: Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(24)),
                            child: TextField(
                              controller: _msgController,
                              onChanged: (_) => _playKeyboardSound(),
                              decoration: InputDecoration(
                                hintText: _composerState.isRecording
                                    ? 'Идет запись...'
                                    : 'Ваше сообщение...',
                                hintStyle: TextStyle(
                                    color: _composerState.isRecording
                                        ? Colors.red
                                        : Colors.grey),
                                border: InputBorder.none,
                              ),
                              readOnly: _composerState.isRecording,
                              onSubmitted: (_) => _onSendText(),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                              _composerState.isRecording ? Icons.stop_circle : Icons.mic,
                              color: _composerState.isRecording
                                  ? Colors.red
                                  : Colors.blueGrey,
                              size: 28),
                          onPressed: _toggleRecording,
                        ),
                        CircleAvatar(
                          backgroundColor: Colors.blueAccent,
                          child: IconButton(
                              icon: const Icon(Icons.send,
                                  color: Colors.white, size: 20),
                              onPressed: _onSendText),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewAudioPanel() {
    return Row(
      children: [
        IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            onPressed: _deleteRecording),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
                color: Colors.blueAccent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(24)),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _togglePreview,
                  child: Icon(
                      _composerState.isPlayingPreview
                          ? Icons.pause_circle
                          : Icons.play_circle,
                      color: Colors.blueAccent,
                      size: 30),
                ),
                const SizedBox(width: 12),
                const Text("Голосовое сообщение",
                    style: TextStyle(
                        color: Colors.blueAccent, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        CircleAvatar(
          backgroundColor: Colors.blueAccent,
          child: IconButton(
              icon: const Icon(Icons.send, color: Colors.white, size: 20),
              onPressed: _sendRecordedVoice),
        ),
      ],
    );
  }
}

// ==========================================
// ПЛЕЕРЫ МЕДИА И ПРОСМОТР ФОТО
// ==========================================

class FullScreenImageViewer extends StatelessWidget {
  final String imageUrl;
  const FullScreenImageViewer({super.key, required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white)),
      body: Center(
        child: InteractiveViewer(
            minScale: 0.1, maxScale: 4.0, child: Image.network(imageUrl)),
      ),
    );
  }
}

class GroupInlineAudioPlayer extends StatefulWidget {
  final String audioUrl;
  final bool isMe;
  const GroupInlineAudioPlayer(
      {super.key, required this.audioUrl, required this.isMe});

  @override
  State<GroupInlineAudioPlayer> createState() => _GroupInlineAudioPlayerState();
}

class _GroupInlineAudioPlayerState extends State<GroupInlineAudioPlayer> {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.setSourceUrl(widget.audioUrl);
    _player.onDurationChanged.listen((d) => setState(() => _duration = d));
    _player.onPositionChanged.listen((p) => setState(() => _position = p));
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _isPlaying = state == PlayerState.playing);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(
              _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill),
          color: widget.isMe ? Colors.white : Colors.blueAccent,
          iconSize: 36,
          onPressed: () {
            _isPlaying
                ? _player.pause()
                : _player.play(UrlSource(widget.audioUrl));
          },
        ),
        SizedBox(
          width: 150,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              activeColor: widget.isMe ? Colors.white : Colors.blueAccent,
              inactiveColor:
                  widget.isMe ? Colors.white54 : Colors.grey.shade300,
              min: 0,
              max: _duration.inSeconds.toDouble() > 0
                  ? _duration.inSeconds.toDouble()
                  : 1.0,
              value: _position.inSeconds.toDouble().clamp(
                  0.0,
                  _duration.inSeconds.toDouble() > 0
                      ? _duration.inSeconds.toDouble()
                      : 1.0),
              onChanged: (val) {
                _player.seek(Duration(seconds: val.toInt()));
              },
            ),
          ),
        ),
      ],
    );
  }
}

// Безопасный видеоплеер (не упадет на ПК)
class GroupInlineVideoPlayer extends StatefulWidget {
  final String videoUrl;
  final VoidCallback onDownload;
  const GroupInlineVideoPlayer(
      {super.key, required this.videoUrl, required this.onDownload});

  @override
  State<GroupInlineVideoPlayer> createState() => _GroupInlineVideoPlayerState();
}

class _GroupInlineVideoPlayerState extends State<GroupInlineVideoPlayer> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      _controller =
          VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
      await _controller!.initialize();
      if (mounted) setState(() => _isInitialized = true);
    } catch (e) {
      if (mounted) setState(() => _hasError = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Container(
        padding: const EdgeInsets.all(16),
        color: Colors.black12,
        child: Column(
          children: [
            const Icon(Icons.videocam_off, color: Colors.white54, size: 40),
            const SizedBox(height: 8),
            const Text("Предпросмотр недоступен",
                style: TextStyle(color: Colors.white)),
            TextButton.icon(
              icon: const Icon(Icons.download, color: Colors.white),
              label: const Text("Скачать видео",
                  style: TextStyle(color: Colors.white)),
              onPressed: widget.onDownload,
            )
          ],
        ),
      );
    }

    if (!_isInitialized) {
      return const SizedBox(
          height: 150,
          width: 200,
          child: Center(child: CircularProgressIndicator(color: Colors.white)));
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        alignment: Alignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 250),
            child: AspectRatio(
                aspectRatio: _controller!.value.aspectRatio,
                child: VideoPlayer(_controller!)),
          ),
          CircleAvatar(
            backgroundColor: Colors.black54,
            radius: 24,
            child: IconButton(
              icon: Icon(
                  _controller!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white),
              onPressed: () => setState(() => _controller!.value.isPlaying
                  ? _controller!.pause()
                  : _controller!.play()),
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_saver/file_saver.dart';
import 'package:record/record.dart';

import '../providers/chat_composer_provider.dart';
import '../providers/chat_messages_provider.dart';
import '../providers/services_providers.dart';
import 'video_call_screen.dart';

enum AttachmentType { image, audio, document }

class ChatScreen extends ConsumerStatefulWidget {
  final RecordModel receiver;
  const ChatScreen({super.key, required this.receiver});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _msgController = TextEditingController();
  late String _myId;

  String get _composerKey => 'direct_${widget.receiver.id}';

  ChatComposerNotifier get _composer =>
      ref.read(chatComposerProvider(_composerKey).notifier);

  ChatComposerState get _composerState =>
      ref.watch(chatComposerProvider(_composerKey));

  ApiService get api => ref.read(apiServiceProvider);

  final AudioPlayer _keyboardSoundPlayer = AudioPlayer();
  final AudioPlayer _messageSoundPlayer = AudioPlayer();
  final AudioPlayer _previewAudioPlayer = AudioPlayer();
  late final AudioRecorder _audioRecorder;

  @override
  void initState() {
    super.initState();
    _myId = api.pb.authStore.record?.id ?? '';
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
      await _messageSoundPlayer.setVolume(0.3);
      await _messageSoundPlayer.play(AssetSource('sounds/mes.mp3'));
    } catch (e) {
      debugPrint("Ошибка звука: $e");
    }
  }

  void _copyToClipboard(String text) {
    HapticFeedback.lightImpact();
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text("Скопировано"), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _sendMessage() async {
    if (_msgController.text.trim().isEmpty) return;
    HapticFeedback.mediumImpact();
    _playMessageSound();

    final text = _msgController.text.trim();
    _msgController.clear();

    try {
      await ref.read(chatMessagesProvider(widget.receiver.id).notifier).sendText(
            text: text,
            editingMessageId: _composerState.editingMessageId,
          );
      _composer.clearEditing();
    } catch (_) {}
  }

  Future<void> _deleteMessage(String id) async {
    try {
      await ref
          .read(chatMessagesProvider(widget.receiver.id).notifier)
          .deleteMessage(id);
    } catch (e) {
      debugPrint('Ошибка удаления: $e');
    }
  }

  // ==========================================
  // ЛОГИКА ЗВОНКА
  // ==========================================
  void _startVideoCall() async {
    if (_myId.isEmpty) return;

    HapticFeedback.heavyImpact();

    String? createdMessageId;
    try {
      createdMessageId = await ref
          .read(chatMessagesProvider(widget.receiver.id).notifier)
          .startVideoCall();
    } catch (e) {
      debugPrint('Ошибка создания звонка: $e');
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

  // ==========================================
  // МЕНЮ СООБЩЕНИЙ (Telegram Style)
  // ==========================================
  void _showMessageOptions(RecordModel m) {
    final isMe = m.getStringValue('sender') == _myId;
    final type = m.getStringValue('type');
    final isRead = m.getBoolValue('is_read');
    final content = m.getStringValue('content');

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
            if (type == 'text')
              ListTile(
                leading: const Icon(Icons.copy, color: Colors.blue),
                title: const Text('Копировать текст'),
                onTap: () {
                  Navigator.pop(context);
                  _copyToClipboard(content);
                },
              ),
            if (type == 'text' && isMe && !isRead)
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
                leading: const Icon(Icons.download, color: Colors.blue),
                title: const Text('Скачать файл'),
                onTap: () {
                  Navigator.pop(context);
                  _downloadAndSaveFile(m);
                },
              ),
            if (isMe && !isRead)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title:
                    const Text('Удалить', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  _deleteMessage(m.id);
                },
              ),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // ДИКТОФОН И ФАЙЛЫ
  // ==========================================
  Future<void> _toggleRecording() async {
    if (_composerState.isRecording) {
      try {
        final path = await _audioRecorder.stop();
        _composer.setRecording(false, filePath: path);
        HapticFeedback.lightImpact();
      } catch (e) {
        debugPrint('Ошибка остановки: $e');
      }
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
      } catch (e) {
        debugPrint('Ошибка записи: $e');
      }
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
      final fileObj = result.files.single;
      if (kIsWeb) {
        if (fileObj.bytes == null) return;
        _sendFileToServer(fileObj.bytes, fileObj.name, isPath: false);
      } else {
        if (fileObj.path == null) return;
        _sendFileToServer(fileObj.path, fileObj.name, isPath: true);
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
      await api.pb.collection('messages').create(
        body: {
          "sender": _myId,
          "receiver": widget.receiver.id,
          "content": fileName,
          "type": "file",
          "is_read": false,
        },
        files: [multipartFile],
      );
    } catch (e) {
      debugPrint("Ошибка отправки: $e");
    } finally {
      if (mounted) _composer.setUploading(false);
    }
  }

  Future<void> _downloadAndSaveFile(RecordModel m) async {
    final String attachmentName = m.getStringValue('attachment');
    if (attachmentName.isEmpty) return;

    if (kIsWeb) {
      final fileUrl = api.pb.files.getUrl(m, attachmentName).toString();
      await launchUrl(Uri.parse(fileUrl));
      return;
    }

    _composer.setDownloading(m.id, true);
    try {
      final fileUrl = api.pb.files.getUrl(m, attachmentName).toString();
      final client = api.pb.httpClientFactory();
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Ошибка сохранения"), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) _composer.setDownloading(m.id, false);
    }
  }

  AttachmentType _getAttachmentType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext)) {
      return AttachmentType.image;
    }
    if (['mp3', 'm4a', 'wav', 'ogg', 'aac'].contains(ext)) {
      return AttachmentType.audio;
    }
    return AttachmentType.document;
  }

  void _openImageFullScreen(String imageUrl) {
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => FullScreenImageViewer(imageUrl: imageUrl)));
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatMessagesProvider(widget.receiver.id));

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
        // ВЕРНУЛИ КНОПКУ ЗВОНКА!
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
            child: chatState.isInitialLoading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 16),
                    itemCount: chatState.messages.length,
                    itemBuilder: (context, index) =>
                        _renderMessage(chatState.messages[index]),
                  ),
          ),
          if (_composerState.isUploading)
            const LinearProgressIndicator(minHeight: 3, color: Colors.blue),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _renderMessage(RecordModel m) {
    final String type = m.getStringValue('type', 'text');
    if (type == 'call_missed' ||
        type == 'call_success' ||
        type == 'call_started') {
      return _buildSystemMessage(m); // ВЕРНУЛИ ПЛАШКИ ЗВОНКОВ!
    }
    return _buildMessageBubble(m);
  }

  // МЕТОД ДЛЯ КРАСИВЫХ ПЛАШЕК О ЗВОНКАХ
  Widget _buildSystemMessage(RecordModel m) {
    final String type = m.getStringValue('type');
    final bool isMe = m.getStringValue('sender') == _myId;

    String text;
    IconData icon;
    Color color;
    Color bgColor;
    Color borderColor;

    if (type == 'call_started') {
      text = isMe ? "📞 Исходящий звонок..." : "📞 Входящий звонок...";
      icon = isMe ? Icons.call_made : Icons.call_received;
      color = Colors.blue.shade700;
      bgColor = Colors.blue.withOpacity(0.1);
      borderColor = Colors.blue.withOpacity(0.2);
    } else if (type == 'call_missed') {
      text = isMe ? "Отмененный звонок" : "Пропущенный звонок";
      icon = isMe ? Icons.call_made : Icons.call_missed;
      color = Colors.red.shade700;
      bgColor = Colors.red.withOpacity(0.1);
      borderColor = Colors.red.withOpacity(0.2);
    } else {
      // call_success
      text = isMe ? "Исходящий видеозвонок" : "Входящий видеозвонок";
      icon = isMe ? Icons.call_made : Icons.call_received;
      color = Colors.green.shade700;
      bgColor = Colors.green.withOpacity(0.1);
      borderColor = Colors.green.withOpacity(0.2);
    }

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: color,
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
    final String attachment = m.getStringValue('attachment');

    Widget bubbleContent;

    if (type == 'file' && attachment.isNotEmpty) {
      final fileUrl = api.pb.files.getUrl(m, attachment).toString();
      final attType = _getAttachmentType(attachment);
      final isDownloading = _composerState.downloadingFiles[m.id] ?? false;

      switch (attType) {
        case AttachmentType.image:
          bubbleContent = GestureDetector(
            onTap: () => _openImageFullScreen(fileUrl),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: Image.network(fileUrl, fit: BoxFit.cover),
              ),
            ),
          );
          break;
        case AttachmentType.audio:
          bubbleContent = InlineAudioPlayer(audioUrl: fileUrl, isMe: isMe);
          break;
        case AttachmentType.document:
          bubbleContent = InkWell(
            onTap: () => _downloadAndSaveFile(m),
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
                          color: isMe ? Colors.white : Colors.blue, size: 30),
                  const SizedBox(width: 12),
                  Flexible(
                      child: Text(content,
                          style: TextStyle(
                              color: isMe ? Colors.white : Colors.black87),
                          overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
          );
          break;
      }
    } else {
      bubbleContent = Text(content,
          style: TextStyle(
              color: isMe ? Colors.white : Colors.black87, fontSize: 16));
    }

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showMessageOptions(m),
        onSecondaryTap: () => _showMessageOptions(m),
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
                  offset: const Offset(0, 2))
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              bubbleContent,
              if (isMe)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_composerState.editingMessageId == m.id)
                        const Icon(Icons.edit, size: 12, color: Colors.white54),
                      if (_composerState.editingMessageId == m.id) const SizedBox(width: 4),
                      Icon(isRead ? Icons.done_all : Icons.done,
                          size: 16,
                          color:
                              isRead ? Colors.lightBlueAccent : Colors.white70),
                    ],
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
      decoration: BoxDecoration(color: Colors.white, boxShadow: [
        BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, -2))
      ]),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ПЛАШКА РЕДАКТИРОВАНИЯ
            if (_composerState.editingMessageId != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: Colors.blue.shade50,
                child: Row(
                  children: [
                    const Icon(Icons.edit, color: Colors.blue, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                        child: Text("Редактирование сообщения",
                            style: TextStyle(
                                color: Colors.blue,
                                fontWeight: FontWeight.bold))),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.blue),
                      onPressed: () {
                        _composer.clearEditing();
                        _msgController.clear();
                      },
                    )
                  ],
                ),
              ),

            // ПАНЕЛЬ ПРЕДПРОСЛУШИВАНИЯ ИЛИ ВВОД ТЕКСТА
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: _composerState.recordedFilePath != null
                  ? _buildPreviewAudioPanel()
                  : Row(
                      children: [
                        IconButton(
                            icon: const Icon(Icons.attach_file,
                                color: Colors.blue),
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
                                    : 'Сообщение...',
                                hintStyle: TextStyle(
                                    color: _composerState.isRecording
                                        ? Colors.red
                                        : Colors.grey),
                                border: InputBorder.none,
                              ),
                              readOnly: _composerState.isRecording,
                              onSubmitted: (_) => _sendMessage(),
                            ),
                          ),
                        ),
                        // КНОПКА МИКРОФОНА
                        IconButton(
                          icon: Icon(
                              _composerState.isRecording ? Icons.stop_circle : Icons.mic,
                              color:
                                  _composerState.isRecording ? Colors.red : Colors.blueGrey,
                              size: 28),
                          onPressed: _toggleRecording,
                        ),
                        // КНОПКА ОТПРАВКИ (Всегда видима)
                        CircleAvatar(
                          backgroundColor: Colors.blue,
                          child: IconButton(
                              icon: const Icon(Icons.send,
                                  color: Colors.white, size: 20),
                              onPressed: _sendMessage),
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
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(24)),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _togglePreview,
                  child: Icon(
                      _composerState.isPlayingPreview
                          ? Icons.pause_circle
                          : Icons.play_circle,
                      color: Colors.blue,
                      size: 30),
                ),
                const SizedBox(width: 12),
                const Text("Голосовое сообщение",
                    style: TextStyle(
                        color: Colors.blue, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        CircleAvatar(
          backgroundColor: Colors.blue,
          child: IconButton(
              icon: const Icon(Icons.send, color: Colors.white, size: 20),
              onPressed: _sendRecordedVoice),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _previewAudioPlayer.dispose();
    _audioRecorder.dispose();
    super.dispose();
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

class InlineAudioPlayer extends StatefulWidget {
  final String audioUrl;
  final bool isMe;
  const InlineAudioPlayer(
      {super.key, required this.audioUrl, required this.isMe});

  @override
  State<InlineAudioPlayer> createState() => _InlineAudioPlayerState();
}

class _InlineAudioPlayerState extends State<InlineAudioPlayer> {
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
          color: widget.isMe ? Colors.white : Colors.blue,
          iconSize: 36,
          onPressed: () => _isPlaying
              ? _player.pause()
              : _player.play(UrlSource(widget.audioUrl)),
        ),
        SizedBox(
          width: 150,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
            child: Slider(
              activeColor: widget.isMe ? Colors.white : Colors.blue,
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
              onChanged: (val) => _player.seek(Duration(seconds: val.toInt())),
            ),
          ),
        ),
      ],
    );
  }
}

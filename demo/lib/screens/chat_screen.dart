import 'package:flutter/material.dart';

import '../demo_data.dart';
import 'call_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.contact});

  final DemoContact contact;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late List<DemoMessage> _messages;
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _messages = List.of(DemoData.messagesFor(widget.contact.id));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _sendMessage() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _messages.insert(
        0,
        DemoMessage(text: text, isMine: true, time: 'сейчас'),
      );
      _controller.clear();
    });
  }

  void _openCall({required bool incoming}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CallScreen(
          contactName: widget.contact.name,
          isIncoming: incoming,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.contact.name),
            Text(
              widget.contact.isOnline ? 'в сети' : 'не в сети',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () => _openCall(incoming: false),
            icon: const Icon(Icons.videocam_rounded),
            tooltip: 'Видеозвонок',
          ),
          IconButton(
            onPressed: () => _openCall(incoming: true),
            icon: const Icon(Icons.call_received_rounded),
            tooltip: 'Симуляция входящего',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              reverse: true,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return _MessageBubble(message: message);
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Отправка файлов — только UI в демо')),
                      );
                    },
                    icon: const Icon(Icons.attach_file),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      decoration: InputDecoration(
                        hintText: 'Сообщение...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _sendMessage,
                    style: FilledButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(14),
                    ),
                    child: const Icon(Icons.send_rounded, size: 20),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final DemoMessage message;

  @override
  Widget build(BuildContext context) {
    final isCall = message.type != DemoMessageType.text;
    final color = message.isMine
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;

    return Align(
      alignment: message.isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isCall)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    message.type == DemoMessageType.callMissed
                        ? Icons.call_missed
                        : Icons.videocam,
                    size: 18,
                    color: message.type == DemoMessageType.callMissed
                        ? Colors.red
                        : Colors.green,
                  ),
                  const SizedBox(width: 6),
                  Flexible(child: Text(message.text)),
                ],
              )
            else
              Text(message.text),
            const SizedBox(height: 4),
            Text(
              message.time,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

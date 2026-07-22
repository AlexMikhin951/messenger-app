import 'dart:async';

import 'package:flutter/material.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.contactName,
    this.isIncoming = false,
  });

  final String contactName;
  final bool isIncoming;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  bool _accepted = false;
  bool _micOn = true;
  bool _cameraOn = true;
  bool _speakerOn = true;
  Timer? _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _accepted = !widget.isIncoming;
    if (_accepted) _startTimer();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _timerLabel {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _accept() {
    setState(() => _accepted = true);
    _startTimer();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1A237E), Color(0xFF000000)],
              ),
            ),
          ),
          if (_accepted)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircleAvatar(
                    radius: 56,
                    backgroundColor: Colors.white24,
                    child: Text(
                      widget.contactName.characters.first,
                      style: const TextStyle(fontSize: 40, color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    widget.contactName,
                    style: const TextStyle(color: Colors.white, fontSize: 24),
                  ),
                  Text(
                    _timerLabel,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    width: 280,
                    height: 160,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Text(
                      'Видеопоток (демо)\nWebRTC не подключён',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ),
            )
          else
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.videocam, color: Colors.white, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    'Входящий видеозвонок',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(color: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.contactName,
                    style: const TextStyle(color: Colors.white70, fontSize: 20),
                  ),
                ],
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 40,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (!_accepted) ...[
                  _RoundButton(
                    icon: Icons.call,
                    color: Colors.green,
                    onTap: _accept,
                  ),
                  _RoundButton(
                    icon: Icons.call_end,
                    color: Colors.red,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ] else ...[
                  _RoundButton(
                    icon: _micOn ? Icons.mic : Icons.mic_off,
                    color: Colors.white24,
                    onTap: () => setState(() => _micOn = !_micOn),
                  ),
                  _RoundButton(
                    icon: _cameraOn ? Icons.videocam : Icons.videocam_off,
                    color: Colors.white24,
                    onTap: () => setState(() => _cameraOn = !_cameraOn),
                  ),
                  _RoundButton(
                    icon: _speakerOn ? Icons.volume_up : Icons.volume_off,
                    color: Colors.white24,
                    onTap: () => setState(() => _speakerOn = !_speakerOn),
                  ),
                  _RoundButton(
                    icon: Icons.call_end,
                    color: Colors.red,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 64,
          height: 64,
          child: Icon(icon, color: Colors.white),
        ),
      ),
    );
  }
}

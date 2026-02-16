import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:pocketbase/pocketbase.dart';
import '../services/signaling_manager.dart';
import '../services/api_service.dart';

class VideoCallScreen extends StatefulWidget {
  final String receiverId;
  final bool isIncoming;
  final String? roomId;
  final String? messageId;

  const VideoCallScreen({
    super.key,
    required this.receiverId,
    this.isIncoming = false,
    this.roomId,
    this.messageId,
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  final SignalingManager _signaling = SignalingManager();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final AudioPlayer _audioPlayer = AudioPlayer();

  Timer? _hideTimer;
  UnsubscribeFunc? _unsubCall;

  String _callerName = "Загрузка...";
  String? _activeRoomId;
  late bool _hasAccepted;
  bool _isRemoteVideoReady = false;
  bool _showControls = true;
  bool _isInitialized = false; // Флаг готовности рендереров

  bool _isMicOn = true;
  bool _isCameraOn = true;
  bool _isSpeakerOn = true;
  bool _isScreenSharing = false;

  List<MediaDeviceInfo> _devices = [];

  @override
  void initState() {
    super.initState();
    _hasAccepted = !widget.isIncoming;
    _activeRoomId = widget.roomId;
    _initialize();
  }

  Future<void> _initialize() async {
    // 1. Сначала инициализируем рендереры
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    _remoteRenderer.onFirstFrameRendered = () {
      if (mounted) setState(() => _isRemoteVideoReady = true);
    };

    await _loadCallerInfo();

    // 2. Настройка звука
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      _loadDevices();
    } else {
      Helper.setSpeakerphoneOn(_isSpeakerOn);
    }

    // 3. Обработка логики звонка
    if (widget.isIncoming) {
      _playRingtone();
      await Future.delayed(const Duration(milliseconds: 500));
      // Важно: начинаем слушать удаление комнаты сразу
      if (_activeRoomId != null) _listenToCallTermination();
    } else {
      // Для исходящего сразу запускаем процесс
      await _startCall();
    }

    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
    _startHideTimer();
  }

  Future<void> _startCall() async {
    final bool isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    // Сначала открываем медиа (камеру/микрофон)
    // Это критически важно сделать ДО joinCall или createCall, чтобы избежать Race Condition
    await _signaling.openUserMedia(
        _localRenderer, _remoteRenderer, isLandscape);

    _signaling.onPeerConnectionState = (state) {
      debugPrint("PeerConnectionState: $state");
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _exit();
      }
    };

    if (widget.isIncoming && _activeRoomId != null) {
      try {
        // Присоединяемся к существующей сессии
        await _signaling.joinCall(_activeRoomId!, _remoteRenderer, context);
      } catch (e) {
        debugPrint("Error joining call: $e");
        _exit();
      }
    } else {
      try {
        // Создаем новую сессию
        _activeRoomId = await _signaling.createCall(
            widget.receiverId, _remoteRenderer, context);
        if (_activeRoomId != null) {
          _listenToCallTermination();
        } else {
          _exit();
        }
      } catch (e) {
        debugPrint("Error creating call: $e");
        _exit();
      }
    }
    if (mounted) setState(() {});
  }

  void _exit() {
    if (!mounted) return;
    _audioPlayer.stop();

    // Выносим hangUp из try-finally для надежности
    _signaling
        .hangUp(_activeRoomId)
        .catchError((e) => debugPrint("Hangup error: $e"));

    if (_unsubCall != null) {
      _unsubCall!();
      _unsubCall = null;
    }

    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  // --- UI Секция ---

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Удаленное видео
          Positioned.fill(
            child: _isRemoteVideoReady
                ? RTCVideoView(_remoteRenderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
                : _buildPlaceholder(),
          ),

          // Детектор нажатий для скрытия контролов
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                setState(() => _showControls = !_showControls);
                if (_showControls) _startHideTimer();
              },
              child: Container(color: Colors.transparent),
            ),
          ),

          if (_hasAccepted) ...[
            if (_isCameraOn) _buildLocalPreview(),
            _buildTopBar(),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              bottom: _showControls ? 40 : -120,
              left: 0,
              right: 0,
              child: Center(child: _buildModernControlPanel()),
            ),
          ],

          if (widget.isIncoming && !_hasAccepted) _buildIncomingCallUI(),
        ],
      ),
    );
  }

  Widget _buildModernControlPanel() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(35),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
          color: Colors.white.withOpacity(0.1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildRoundBtn(
                icon: _isMicOn ? Icons.mic : Icons.mic_off,
                active: _isMicOn,
                onPressed: () {
                  setState(() => _isMicOn = !_isMicOn);
                  _signaling.localStream
                      ?.getAudioTracks()
                      .forEach((t) => t.enabled = _isMicOn);
                },
              ),
              const SizedBox(width: 12),
              _buildRoundBtn(
                icon: _isCameraOn ? Icons.videocam : Icons.videocam_off,
                active: _isCameraOn,
                onPressed: () {
                  setState(() => _isCameraOn = !_isCameraOn);
                  _signaling.localStream
                      ?.getVideoTracks()
                      .forEach((t) => t.enabled = _isCameraOn);
                },
              ),
              const SizedBox(width: 12),
              if (Platform.isWindows || Platform.isMacOS) ...[
                _buildRoundBtn(
                  icon: Icons.monitor,
                  active: _isScreenSharing,
                  onPressed: _toggleScreenShare,
                  color: _isScreenSharing
                      ? Colors.orangeAccent
                      : Colors.blueAccent,
                ),
                const SizedBox(width: 12),
                _buildRoundBtn(
                  icon: Icons.settings,
                  active: true,
                  onPressed: _showDevicePicker,
                  color: Colors.grey.shade700,
                ),
              ] else ...[
                _buildRoundBtn(
                  icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_down,
                  active: _isSpeakerOn,
                  onPressed: () {
                    setState(() => _isSpeakerOn = !_isSpeakerOn);
                    Helper.setSpeakerphoneOn(_isSpeakerOn);
                  },
                ),
                const SizedBox(width: 12),
                _buildRoundBtn(
                  icon: Icons.flip_camera_ios,
                  active: true,
                  onPressed: () {
                    if (_signaling.localStream != null &&
                        _signaling.localStream!.getVideoTracks().isNotEmpty) {
                      Helper.switchCamera(
                          _signaling.localStream!.getVideoTracks().first);
                    }
                  },
                ),
              ],
              const SizedBox(width: 12),
              _buildRoundBtn(
                icon: Icons.call_end,
                active: false,
                color: Colors.redAccent,
                onPressed: _exit,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoundBtn(
      {required IconData icon,
      required bool active,
      required VoidCallback onPressed,
      Color? color}) {
    return SizedBox(
      width: 52,
      height: 52,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color ??
                  (active ? Colors.white24 : Colors.red.withOpacity(0.8)),
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
      ),
    );
  }

  Widget _buildLocalPreview() {
    final bool isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    double width = Platform.isWindows ? 200.0 : (isLandscape ? 180.0 : 120.0);
    double height = Platform.isWindows ? 120.0 : (isLandscape ? 120.0 : 180.0);

    return Positioned(
      top: 60,
      right: 20,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
              color: Colors.black, border: Border.all(color: Colors.white24)),
          child: RTCVideoView(_localRenderer,
              mirror: !_isScreenSharing,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
        ),
      ),
    );
  }

  Widget _buildIncomingCallUI() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1E272E), Colors.black]),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          const CircleAvatar(
              radius: 70,
              backgroundColor: Colors.white10,
              child: Icon(Icons.person, size: 80, color: Colors.white)),
          const SizedBox(height: 24),
          Text(_callerName,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold)),
          const Text("Входящий видеозвонок",
              style: TextStyle(color: Colors.white54, fontSize: 16)),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(bottom: 80),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildCallActionBtn(
                    Icons.close, "Отклонить", Colors.redAccent, _exit),
                _buildCallActionBtn(
                    Icons.videocam, "Принять", Colors.greenAccent, () async {
                  _audioPlayer.stop();
                  setState(() => _hasAccepted = true);
                  await _startCall();
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCallActionBtn(
      IconData icon, String label, Color color, VoidCallback onTap) {
    return Column(
      children: [
        SizedBox(
          width: 70,
          height: 70,
          child: Material(
            color: color,
            shape: const CircleBorder(),
            child: InkWell(
                onTap: onTap,
                customBorder: const CircleBorder(),
                child: Icon(icon, color: Colors.white, size: 30)),
          ),
        ),
        const SizedBox(height: 10),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
      ],
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: const Color(0xFF121212),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircleAvatar(
              radius: 60,
              backgroundColor: Colors.white10,
              child: Icon(Icons.person, size: 60, color: Colors.white24)),
          const SizedBox(height: 20),
          Text(_hasAccepted ? "Подключение..." : "Звонок...",
              style: const TextStyle(color: Colors.white70, fontSize: 18)),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Container(
            margin: const EdgeInsets.only(top: 20),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
                color: Colors.black54, borderRadius: BorderRadius.circular(30)),
            child: Text(_callerName,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ),
      ),
    );
  }

  Future<void> _loadCallerInfo() async {
    try {
      final user =
          await ApiService().pb.collection('users').getOne(widget.receiverId);
      if (mounted) {
        setState(() => _callerName = user.getStringValue('name').isNotEmpty
            ? user.getStringValue('name')
            : user.getStringValue('username'));
      }
    } catch (_) {
      if (mounted) setState(() => _callerName = "Абонент");
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _hasAccepted) setState(() => _showControls = false);
    });
  }

  Future<void> _listenToCallTermination() async {
    if (_activeRoomId == null) return;
    try {
      _unsubCall = await ApiService()
          .pb
          .collection('calls')
          .subscribe(_activeRoomId!, (e) {
        if (e.action == 'delete' && mounted) _exit();
      });
    } catch (e) {
      debugPrint("Subscription error: $e");
    }
  }

  Future<void> _playRingtone() async {
    try {
      // В ЭТОМ БЛОКЕ ВООБЩЕ НЕТ СЛОВА 'const'
      // Это гарантирует, что ошибка "const_with_non_const" исчезнет
      await _audioPlayer.setAudioContext(AudioContext(
        android: AudioContextAndroid(
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.notificationRingtone,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.ambient,
        ),
      ));

      await _audioPlayer.setReleaseMode(ReleaseMode.loop);

      // Проверь, что файл называется именно ringtone.mp3
      await _audioPlayer.play(AssetSource('sounds/Ring.mp3'));

      debugPrint("Рингтон запущен успешно");
    } catch (e) {
      debugPrint("Ошибка плеера: $e");
    }
  }

  Future<void> _loadDevices() async {
    _devices = await navigator.mediaDevices.enumerateDevices();
    if (mounted) setState(() {});
  }

  void _showDevicePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDeviceCategory(
                "Камера",
                Icons.videocam,
                _devices.where((d) => d.kind == 'videoinput').toList(),
                (id) => _switchDevice('video', id)),
            _buildDeviceCategory(
                "Микрофон",
                Icons.mic,
                _devices.where((d) => d.kind == 'audioinput').toList(),
                (id) => _switchDevice('audio', id)),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceCategory(String title, IconData icon,
      List<MediaDeviceInfo> items, Function(String) onSelect) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(color: Colors.white60, fontSize: 12)),
      ...items.map((d) => ListTile(
            leading: Icon(icon, color: Colors.blueAccent),
            title: Text(d.label,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
            onTap: () {
              onSelect(d.deviceId);
              Navigator.pop(context);
            },
          )),
    ]);
  }

  Future<void> _switchDevice(String type, String id) async {
    if (type == 'video') {
      await _signaling.localStream
          ?.getVideoTracks()
          .firstOrNull
          ?.applyConstraints({"deviceId": id});
    }
    if (type == 'audio') {
      await _signaling.localStream
          ?.getAudioTracks()
          .firstOrNull
          ?.applyConstraints({"deviceId": id});
    }
  }

  Future<void> _toggleScreenShare() async {
    bool newState = !_isScreenSharing;
    await _signaling.switchScreenShare(_localRenderer, newState,
        context: context);
    setState(() => _isScreenSharing = newState);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    if (_unsubCall != null) _unsubCall!();
    _audioPlayer.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }
}

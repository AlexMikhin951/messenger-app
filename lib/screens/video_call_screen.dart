import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../providers/services_providers.dart';

class VideoCallScreen extends ConsumerStatefulWidget {
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
  ConsumerState<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends ConsumerState<VideoCallScreen> {
  SignalingManager get _signaling => ref.read(signalingManagerProvider);
  ApiService get api => ref.read(apiServiceProvider);
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final AudioPlayer _audioPlayer = AudioPlayer();

  Timer? _hideTimer;
  Timer? _dialTimeoutTimer;
  UnsubscribeFunc? _unsubCall;

  bool _isHangingUp = false;
  bool _isCallSuccessful = false;

  String _callerName = "Загрузка...";
  String? _activeRoomId;
  late bool _hasAccepted;
  bool _isRemoteVideoReady = false;
  bool _showControls = true;
  bool _isInitialized = false;

  bool _isMicOn = true;
  bool _isCameraOn = true;
  bool _isSpeakerOn = true;
  bool _isScreenSharing = false;

  List<MediaDeviceInfo> _devices = [];

  bool get _isDesktopOrWeb =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    _hasAccepted = !widget.isIncoming;
    _activeRoomId = widget.roomId;

    _signaling.isMinimized.value = false;
    WakelockPlus.enable();

    _initialize();
  }

  Future<void> _initialize() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    _remoteRenderer.onFirstFrameRendered = () {
      if (mounted) setState(() => _isRemoteVideoReady = true);
    };

    await _loadCallerInfo();

    if (_isDesktopOrWeb) {
      await _loadDevices();
    } else {
      Helper.setSpeakerphoneOn(_isSpeakerOn);
    }

    // --- ПРОВЕРЯЕМ, ВОССТАНАВЛИВАЕМ ЛИ МЫ ЗВОНОК ИЗ ОВЕРЛЕЯ ---
    bool isRestoring = _signaling.localStream != null;

    if (isRestoring) {
      // Звонок уже идет!
      _hasAccepted = true;
      _isCallSuccessful = true;
      _isRemoteVideoReady = _signaling.remoteStream != null;

      // Биндим уже существующие потоки к новым рендерерам
      _localRenderer.srcObject = _signaling.localStream;
      _remoteRenderer.srcObject = _signaling.remoteStream;

      // ВАЖНО: Обновляем слушатель состояния для этого нового экрана,
      // иначе экран не закроется, если собеседник повесит трубку.
      _signaling.onPeerConnectionState = _handleConnectionState;

      if (mounted) {
        setState(() => _isInitialized = true);
      }
      _startHideTimer();
      return; // Выходим отсюда, инициализация нового звонка не нужна!
    }

    // --- ЛОГИКА НОВОГО ЗВОНКА ---
    if (widget.isIncoming) {
      _playRingtone();
      await Future.delayed(const Duration(milliseconds: 500));
      if (_activeRoomId != null) _listenToCallTermination();
    } else {
      _playDialTone(); // Звук играет ТОЛЬКО если это новый исходящий звонок
      await _startCall();
    }

    if (mounted) {
      setState(() => _isInitialized = true);
    }
    _startHideTimer();

    _dialTimeoutTimer = Timer(const Duration(seconds: 60), () {
      if (mounted && !_isCallSuccessful) {
        debugPrint("Таймаут дозвона (60 сек). Сбрасываем вызов.");
        _exit();
      }
    });
  }

  Future _markCallAsSuccess() async {
    if (_isCallSuccessful) return;
    _isCallSuccessful = true;
    _dialTimeoutTimer?.cancel(); // ТЕПЕРЬ ТАЙМЕР ОТМЕНИТСЯ ВСЕГДА
    debugPrint("Звонок успешно установлен, таймер таймаута отменен.");

    if (widget.messageId == null) return;

    try {
      await api.pb.collection('messages').update(
        widget.messageId!,
        body: {
          "type": "call_success",
          "is_read": true,
        },
      );
    } catch (e) {
      debugPrint("Ошибка обновления на call_success: $e");
    }
  }

  Future<void> _startCall() async {
    final bool isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    // Передаем наш новый метод
    _signaling.onPeerConnectionState = _handleConnectionState;

    if (widget.isIncoming && _activeRoomId != null) {
      try {
        await _signaling.joinCall(_activeRoomId!, _localRenderer,
            _remoteRenderer, context, isLandscape);
      } catch (e) {
        debugPrint("Error joining call: $e");
        _exit();
      }
    } else {
      try {
        _activeRoomId = await _signaling.createCall(widget.receiverId,
            _localRenderer, _remoteRenderer, context, isLandscape);

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

  Future<void> _exit() async {
    _isHangingUp = true;
    _signaling.isMinimized.value = false;
    _dialTimeoutTimer?.cancel();

    if (!mounted) return;
    _audioPlayer.stop();

    if (widget.messageId != null && !_isCallSuccessful) {
      try {
        await api.pb.collection('messages').update(
          widget.messageId!,
          body: {"type": "call_missed"},
        );
      } catch (e) {
        debugPrint("Ошибка обновления статуса звонка на missed: $e");
      }
    }

    // ИСПРАВЛЕНИЕ КАМЕРЫ 1: Отвязываем потоки от UI перед завершением
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;

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

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator()));
    }

    return _buildFullScreenUI();
  }

  Widget _buildFullScreenUI() {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && !_isHangingUp) {
          _signaling.isGroupCall = false;
          _signaling.currentRoomId = _activeRoomId;
          _signaling.currentReceiverId = widget.receiverId;
          _signaling.isMinimized.value = true;
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: _isRemoteVideoReady
                  ? RTCVideoView(_remoteRenderer,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
                  : _buildPlaceholder(),
            ),
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
              AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: SafeArea(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10, left: 10),
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.close_fullscreen,
                              color: Colors.white, size: 28),
                          onPressed: () {
                            _signaling.isGroupCall = false;
                            _signaling.currentRoomId = _activeRoomId;
                            _signaling.currentReceiverId = widget.receiverId;
                            _signaling.isMinimized.value = true;
                            if (Navigator.canPop(context)) {
                              Navigator.pop(context);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              bottom: _showControls ? 40 : -120,
              left: 0,
              right: 0,
              child: Center(child: _buildModernControlPanel()),
            ),
            if (widget.isIncoming && !_hasAccepted) _buildIncomingCallUI(),
          ],
        ),
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
              if (_isDesktopOrWeb) ...[
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

    double width = _isDesktopOrWeb ? 240.0 : (isLandscape ? 180.0 : 120.0);
    double height = _isDesktopOrWeb ? 135.0 : (isLandscape ? 120.0 : 180.0);

    return Positioned(
      top: 60,
      right: 20,
      child: GestureDetector(
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
                  _markCallAsSuccess();
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
          await api.pb.collection('users').getOne(widget.receiverId);
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
      _unsubCall = await api
          .pb
          .collection('calls')
          .subscribe(_activeRoomId!, (e) {
        if (e.action == 'delete' && mounted) _exit();
      });
    } catch (e) {
      debugPrint("Subscription error: $e");
    }
  }

  Future<void> _playDialTone() async {
    try {
      if (!kIsWeb) {
        await _audioPlayer.setAudioContext(AudioContext(
          android: AudioContextAndroid(
            contentType: AndroidContentType.speech,
            usageType:
                AndroidUsageType.voiceCommunication, // Переводим в режим звонка
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playAndRecord,
            options: {
              AVAudioSessionOptions.allowBluetooth,
              AVAudioSessionOptions.defaultToSpeaker
            },
          ),
        ));
      }
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.play(AssetSource('sounds/DialTone.mp3'));
    } catch (e) {
      debugPrint("Ошибка гудков: $e");
    }
  }

  Future<void> _playRingtone() async {
    if (kIsWeb) {
      try {
        await _audioPlayer.setReleaseMode(ReleaseMode.loop);
        await _audioPlayer.play(AssetSource('sounds/Ring.mp3'));
      } catch (e) {
        debugPrint("Web autoplay prevented: $e");
      }
      return;
    }

    try {
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
      await _audioPlayer.play(AssetSource('sounds/Ring.mp3'));
    } catch (e) {
      debugPrint("Ошибка плеера: $e");
    }
  }

  Future<void> _loadDevices() async {
    try {
      _devices = await navigator.mediaDevices.enumerateDevices();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint("Error loading devices: $e");
    }
  }

  void _showDevicePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDeviceCategory(
                  "Камера",
                  Icons.videocam,
                  _devices.where((d) => d.kind == 'videoinput').toList(),
                  (id) => _switchDevice('video', id)),
              const Divider(color: Colors.white10, height: 30),
              _buildDeviceCategory(
                  "Микрофон (Вход)",
                  Icons.mic,
                  _devices.where((d) => d.kind == 'audioinput').toList(),
                  (id) => _switchDevice('audio', id)),
              const Divider(color: Colors.white10, height: 30),
              _buildDeviceCategory(
                  "Вывод звука (Динамики)",
                  Icons.speaker,
                  _devices.where((d) => d.kind == 'audiooutput').toList(),
                  (id) => _switchDevice('output', id)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceCategory(String title, IconData icon,
      List<MediaDeviceInfo> items, Function(String) onSelect) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: const TextStyle(
              color: Colors.blueAccent,
              fontSize: 12,
              fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      if (items.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8.0),
          child: Text("Устройства не найдены",
              style: TextStyle(color: Colors.white38, fontSize: 13)),
        ),
      ...items.map((d) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(icon, color: Colors.white70, size: 20),
            title: Text(
                d.label.isNotEmpty
                    ? d.label
                    : "Устройство ${d.deviceId.substring(0, 5)}",
                style: const TextStyle(color: Colors.white, fontSize: 14),
                overflow: TextOverflow.ellipsis),
            onTap: () {
              onSelect(d.deviceId);
              Navigator.pop(context);
            },
          )),
    ]);
  }

  Future<void> _switchDevice(String type, String id) async {
    try {
      if (type == 'video') {
        await _signaling.localStream
            ?.getVideoTracks()
            .firstOrNull
            ?.applyConstraints({"deviceId": id});
      } else if (type == 'audio') {
        await _signaling.localStream
            ?.getAudioTracks()
            .firstOrNull
            ?.applyConstraints({"deviceId": id});
      } else if (type == 'output') {
        await _remoteRenderer.audioOutput(id);
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint("Switch device error: $e");
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
    _dialTimeoutTimer?.cancel();

    if (_unsubCall != null) _unsubCall!();

    WakelockPlus.disable();

    // ИСПРАВЛЕНИЕ КАМЕРЫ 2: Гарантированно отвязываем камеру от UI при уничтожении виджета
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;

    // ИСПРАВЛЕНИЕ НАУШНИКОВ: Возвращаем аудио-профиль телефона в режим "Медиа/Музыка"
    if (!kIsWeb) {
      try {
        _audioPlayer.setAudioContext(AudioContext(
          android: AudioContextAndroid(
            contentType: AndroidContentType.music,
            usageType: AndroidUsageType.media,
            audioFocus: AndroidAudioFocus.gain,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.ambient,
          ),
        ));
        Helper.setSpeakerphoneOn(false); // Сбрасываем громкую связь WebRTC
      } catch (e) {
        debugPrint("Ошибка сброса AudioContext: $e");
      }
    }

    _audioPlayer.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  void _handleConnectionState(RTCPeerConnectionState state) {
    debugPrint("PeerConnectionState: $state");

    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      _audioPlayer.stop();
      _markCallAsSuccess();
    }

    if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
        state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
        state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
      _exit();
    }
  }
}

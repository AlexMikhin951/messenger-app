import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
// Используем foundation для проверки платформы без крашей в Web
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
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
  // Используем Singleton SignalingManager, чтобы не плодить подключения
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
  bool _isInitialized = false;

  bool _isMicOn = true;
  bool _isCameraOn = true;
  bool _isSpeakerOn = true;
  bool _isScreenSharing = false;

  List<MediaDeviceInfo> _devices = [];

  // --- ИСПРАВЛЕНИЕ: Добавлен Linux и macOS для унификации интерфейса ---
  bool get _isDesktopOrWeb =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux || // <-- Добавлено
      defaultTargetPlatform == TargetPlatform.macOS; // <-- Добавлено

  @override
  void initState() {
    super.initState();
    _hasAccepted = !widget.isIncoming;
    _activeRoomId = widget.roomId;
    _initialize();
  }

  Future<void> _initialize() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    _remoteRenderer.onFirstFrameRendered = () {
      if (mounted) setState(() => _isRemoteVideoReady = true);
    };

    await _loadCallerInfo();

    // Загружаем список устройств, если это Десктоп или Веб
    if (_isDesktopOrWeb) {
      await _loadDevices();
    } else {
      // Логика только для Android/iOS
      Helper.setSpeakerphoneOn(_isSpeakerOn);
    }

    if (widget.isIncoming) {
      _playRingtone();
      // Небольшая задержка перед подпиской, чтобы UI успел отрисоваться
      await Future.delayed(const Duration(milliseconds: 500));
      if (_activeRoomId != null) _listenToCallTermination();
    } else {
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
    // Определяем ориентацию (важно для мобилок, на десктопе обычно landscape)
    final bool isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

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
        await _signaling.joinCall(_activeRoomId!, _remoteRenderer, context);
      } catch (e) {
        debugPrint("Error joining call: $e");
        _exit();
      }
    } else {
      try {
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Удаленное видео (во весь экран)
          Positioned.fill(
            child: _isRemoteVideoReady
                ? RTCVideoView(_remoteRenderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
                : _buildPlaceholder(),
          ),

          // Тап для скрытия/показа контролов
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

          // Интерфейс активного звонка
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

          // Интерфейс входящего звонка (ответ/отбой)
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
              // Микрофон
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

              // Камера
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

              // --- ДЕСКТОПНЫЕ КНОПКИ (WEB / WIN / LINUX / MAC) ---
              if (_isDesktopOrWeb) ...[
                // Демонстрация экрана
                _buildRoundBtn(
                  icon: Icons.monitor,
                  active: _isScreenSharing,
                  onPressed: _toggleScreenShare,
                  color: _isScreenSharing
                      ? Colors.orangeAccent
                      : Colors.blueAccent,
                ),
                const SizedBox(width: 12),

                // Настройки (Выбор устройств)
                _buildRoundBtn(
                  icon: Icons.settings,
                  active: true,
                  onPressed: _showDevicePicker,
                  color: Colors.grey.shade700,
                ),
              ] else ...[
                // --- МОБИЛЬНЫЕ КНОПКИ ---
                // Громкая связь
                _buildRoundBtn(
                  icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_down,
                  active: _isSpeakerOn,
                  onPressed: () {
                    setState(() => _isSpeakerOn = !_isSpeakerOn);
                    Helper.setSpeakerphoneOn(_isSpeakerOn);
                  },
                ),
                const SizedBox(width: 12),
                // Смена камеры
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

              // Завершить звонок
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

    // --- УНИФИКАЦИЯ: Теперь Web, Windows и Linux используют одинаковые размеры ---
    // Это обеспечивает единый вид интерфейса на всех "больших" системах
    double width = _isDesktopOrWeb ? 240.0 : (isLandscape ? 180.0 : 120.0);
    double height = _isDesktopOrWeb ? 135.0 : (isLandscape ? 120.0 : 180.0);

    return Positioned(
      top: 60,
      right: 20,
      child: GestureDetector(
        // Можно добавить перетаскивание окна (Draggable), если захотите в будущем
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
                color: Colors.black, border: Border.all(color: Colors.white24)),
            child: RTCVideoView(_localRenderer,
                mirror: !_isScreenSharing, // Зеркалим только если это камера
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
      // На Linux этот код иногда требует установленного libmpv или vlc
      // Но audioplayers обычно имеет фоллбек
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

      debugPrint("Рингтон запущен успешно");
    } catch (e) {
      debugPrint("Ошибка плеера: $e");
    }
  }

  Future<void> _loadDevices() async {
    try {
      // Получаем все устройства (камеры, микрофоны, динамики)
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
              // --- НОВЫЙ БЛОК: ВЫБОР ДИНАМИКОВ ---
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
        // Ключевой момент: устанавливаем ID устройства вывода для удаленного потока
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
    if (_unsubCall != null) _unsubCall!();
    _audioPlayer.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }
}

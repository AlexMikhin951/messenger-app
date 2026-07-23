import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../providers/services_providers.dart';

class GroupCallScreen extends ConsumerStatefulWidget {
  final String roomName;
  final String userName;
  final String identity;
  final String? messageId;

  const GroupCallScreen({
    super.key,
    required this.roomName,
    required this.userName,
    required this.identity,
    this.messageId,
  });

  @override
  ConsumerState<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends ConsumerState<GroupCallScreen> {
  LiveKitService get _liveKitService => ref.read(liveKitServiceProvider);
  SignalingManager get _signaling => ref.read(signalingManagerProvider);
  ApiService get api => ref.read(apiServiceProvider);

  List<Participant> participants = [];
  Room? _room;
  bool _isLoading = true;
  bool _isHangingUp = false;
  Participant? _focusParticipant;

  bool _isMicEnabled = true;
  bool _isCameraEnabled = true;
  bool _isScreenShareEnabled = false;

  @override
  void initState() {
    super.initState();
    _signaling.isMinimized.value = false;
    WakelockPlus.enable();

    if (_signaling.currentLiveKitRoom != null) {
      _room = _signaling.currentLiveKitRoom;
      _room!.addListener(_onRoomDidUpdate);
      _onRoomDidUpdate();
      setState(() => _isLoading = false);
    } else {
      _checkPermissionsAndConnect();
    }
  }

  Future<void> _checkPermissionsAndConnect() async {
    await [Permission.camera, Permission.microphone].request();
    _connect();
  }

  Future<void> _connect() async {
    try {
      _room =
          await _liveKitService.joinGroupCall(widget.roomName, widget.identity);
      if (_room == null) throw Exception("Не удалось подключиться");

      if (_room!.remoteParticipants.length >= 6) {
        _room?.disconnect();
        throw Exception("Комната полна (макс. 6 человек)");
      }

      _signaling.currentLiveKitRoom = _room;

      // 🔥 Теперь это единственный и правильный запуск медиа
      await _room!.localParticipant?.setCameraEnabled(_isCameraEnabled);
      await _room!.localParticipant?.setMicrophoneEnabled(_isMicEnabled);

      _room!.addListener(_onRoomDidUpdate);
      _onRoomDidUpdate();

      setState(() => _isLoading = false);
    } catch (e) {
      if (mounted) {
        _isHangingUp = true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("$e"), backgroundColor: Colors.red),
        );
        Navigator.pop(context);
      }
    }
  }

  void _onRoomDidUpdate() {
    if (!mounted || _room == null) return;

    final newParticipants = <Participant>[];
    if (_room!.localParticipant != null) {
      newParticipants.add(_room!.localParticipant!);
    }
    newParticipants.addAll(_room!.remoteParticipants.values);

    if (newParticipants.length > 6 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Внимание: превышен лимит участников")),
      );
    }

    setState(() {
      participants = newParticipants;
      if (_focusParticipant != null &&
          !participants.contains(_focusParticipant)) {
        _focusParticipant = null;
      }
    });
  }

  Future<void> _leaveCall() async {
    if (_isHangingUp) return;
    _isHangingUp = true;
    _signaling.isMinimized.value = false;

    _room?.removeListener(_onRoomDidUpdate);
    final roomToDispose = _room;
    final int remainingParticipants =
        roomToDispose?.remoteParticipants.length ?? 0;

    _room = null;
    _signaling.currentLiveKitRoom = null;

    if (mounted) {
      Navigator.of(context).pop();
    }

    if (roomToDispose != null) {
      try {
        final local = roomToDispose.localParticipant;
        if (local != null) {
          local.setCameraEnabled(false);
          local.setMicrophoneEnabled(false);
          local.setScreenShareEnabled(false);
        }

        await roomToDispose.disconnect();
        await roomToDispose.dispose();

        if (remainingParticipants == 0 && widget.messageId != null) {
          await api
              .pb
              .collection('group_messages')
              .update(widget.messageId!, body: {"type": "call_ended"});
        }
      } catch (e) {
        debugPrint("Ошибка при фоновом завершении звонка: $e");
      }
    }
  }

  Widget _buildAdaptiveGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        int count = participants.length;
        int crossAxisCount;
        double childAspectRatio;

        if (constraints.maxWidth > 800) {
          if (count == 1) {
            crossAxisCount = 1;
            childAspectRatio = constraints.maxWidth / constraints.maxHeight;
          } else if (count == 2) {
            crossAxisCount = 2;
            childAspectRatio =
                (constraints.maxWidth / 2) / constraints.maxHeight;
          } else {
            crossAxisCount = 3;
            childAspectRatio = 1.3;
          }
        } else {
          if (count == 1) {
            crossAxisCount = 1;
            childAspectRatio = 0.8;
          } else {
            crossAxisCount = 2;
            childAspectRatio =
                MediaQuery.of(context).orientation == Orientation.landscape
                    ? 1.6
                    : 0.8;
          }
        }

        return GridView.builder(
          padding: const EdgeInsets.all(12),
          physics: const BouncingScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: childAspectRatio,
          ),
          itemCount: count,
          itemBuilder: (context, index) {
            final participant = participants[index];
            return GestureDetector(
              onTap: () => setState(() => _focusParticipant = participant),
              child: ParticipantWidget(
                key: ValueKey(participant.sid ?? participant.identity),
                participant: participant,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildFocusView() {
    return Stack(
      children: [
        Positioned.fill(
          child: ParticipantWidget(
              key: ValueKey(
                  _focusParticipant!.sid ?? _focusParticipant!.identity),
              participant: _focusParticipant!,
              isFocus: true),
        ),
        Positioned(
          top: 40,
          right: 20,
          child: CircleAvatar(
            backgroundColor: Colors.black45,
            child: IconButton(
              icon: const Icon(Icons.close_fullscreen, color: Colors.white),
              onPressed: () => setState(() => _focusParticipant = null),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && !_isHangingUp && _room != null) {
          _signaling.isGroupCall = true;
          _signaling.groupRoomName = widget.roomName;
          _signaling.groupUserName = widget.userName;
          _signaling.groupIdentity = widget.identity;
          _signaling.groupMessageId = widget.messageId;
          _signaling.isMinimized.value = true;
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: _focusParticipant == null
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.fullscreen_exit),
                  onPressed: () {
                    _signaling.isGroupCall = true;
                    _signaling.groupRoomName = widget.roomName;
                    _signaling.groupUserName = widget.userName;
                    _signaling.groupIdentity = widget.identity;
                    _signaling.groupMessageId = widget.messageId;
                    _signaling.isMinimized.value = true;
                    Navigator.pop(context);
                  },
                ),
                title: Text("Группа (${participants.length}/6)"),
                backgroundColor: Colors.transparent,
                foregroundColor: Colors.white,
                actions: [
                  IconButton(
                      icon: const Icon(Icons.settings_suggest_rounded),
                      onPressed: _showDevicePicker),
                ],
              )
            : null,
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: _focusParticipant != null
                        ? _buildFocusView()
                        : _buildAdaptiveGrid(),
                  ),
                  _buildControlBar(),
                ],
              ),
      ),
    );
  }

  Future<void> _toggleMic() async {
    _isMicEnabled = !_isMicEnabled;
    await _room?.localParticipant?.setMicrophoneEnabled(_isMicEnabled);
    setState(() {});
  }

  Future<void> _toggleCamera() async {
    _isCameraEnabled = !_isCameraEnabled;
    await _room?.localParticipant?.setCameraEnabled(_isCameraEnabled);
    setState(() {});
  }

  Future<void> _toggleScreenShare() async {
    _isScreenShareEnabled = !_isScreenShareEnabled;
    try {
      await _room?.localParticipant
          ?.setScreenShareEnabled(_isScreenShareEnabled);
    } catch (e) {
      _isScreenShareEnabled = false;
    }
    setState(() {});
  }

  Future<void> _showDevicePicker() async {
    final videoDevices = await Hardware.instance.videoInputs();
    final audioInputs = await Hardware.instance.audioInputs();
    final audioOutputs = await Hardware.instance.audioOutputs();
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Настройки",
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const Divider(color: Colors.white24),
              _buildDeviceList(
                  "Камера", videoDevices, (d) => _room?.setVideoInputDevice(d)),
              _buildDeviceList("Микрофон", audioInputs,
                  (d) => _room?.setAudioInputDevice(d)),
              _buildDeviceList("Выход звука", audioOutputs,
                  (d) => _room?.setAudioOutputDevice(d)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceList(
      String title, List<MediaDevice> devices, Function(MediaDevice) onSelect) {
    if (devices.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                color: Colors.blueAccent, fontWeight: FontWeight.bold)),
        ...devices.map((d) => ListTile(
              title: Text(d.label,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              onTap: () {
                onSelect(d);
                Navigator.pop(context);
              },
            )),
      ],
    );
  }

  Widget _buildControlBar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      color: Colors.grey[900],
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
                icon: Icon(_isMicEnabled ? Icons.mic : Icons.mic_off,
                    color: _isMicEnabled ? Colors.white : Colors.red),
                onPressed: _toggleMic),
            IconButton(
                icon: Icon(
                    _isCameraEnabled ? Icons.videocam : Icons.videocam_off,
                    color: _isCameraEnabled ? Colors.white : Colors.red),
                onPressed: _toggleCamera),
            IconButton(
                icon: Icon(Icons.screen_share,
                    color: _isScreenShareEnabled ? Colors.green : Colors.white),
                onPressed: _toggleScreenShare),
            const SizedBox(width: 20),
            FloatingActionButton(
              backgroundColor: Colors.red,
              mini: true,
              onPressed: _leaveCall,
              child: const Icon(Icons.call_end, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _room?.removeListener(_onRoomDidUpdate);

    if (!_signaling.isMinimized.value && _room != null) {
      final roomToDispose = _room!;
      final int remainingParticipants = roomToDispose.remoteParticipants.length;

      roomToDispose.localParticipant?.setCameraEnabled(false);
      roomToDispose.localParticipant?.setMicrophoneEnabled(false);

      roomToDispose.disconnect().then((_) {
        roomToDispose.dispose();
      });

      if (remainingParticipants == 0 && widget.messageId != null) {
        api.pb.collection('group_messages').update(widget.messageId!,
            body: {"type": "call_ended"}).catchError((_) {});
      }
    }

    WakelockPlus.disable();
    super.dispose();
  }
}

class ParticipantWidget extends StatefulWidget {
  final Participant participant;
  final bool isFocus;

  const ParticipantWidget(
      {super.key, required this.participant, this.isFocus = false});

  @override
  State<ParticipantWidget> createState() => _ParticipantWidgetState();
}

class _ParticipantWidgetState extends State<ParticipantWidget> {
  VideoTrack? videoTrack;
  void Function()? _cancelEvents;

  @override
  void initState() {
    super.initState();
    _setupListeners();
  }

  void _setupListeners() {
    _cancelEvents?.call();
    _cancelEvents = widget.participant.events.listen((event) {
      if (mounted) _onParticipantChanged();
    });

    widget.participant.addListener(_onParticipantChanged);
    _onParticipantChanged(); // Вызываем сразу для проверки
  }

  @override
  void didUpdateWidget(covariant ParticipantWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.participant != widget.participant) {
      oldWidget.participant.removeListener(_onParticipantChanged);
      _setupListeners();
    }
  }

  @override
  void dispose() {
    _cancelEvents?.call();
    widget.participant.removeListener(_onParticipantChanged);
    super.dispose();
  }

  void _onParticipantChanged() {
    if (!mounted) return;

    VideoTrack? newTrack;
    final pubs = widget.participant.videoTrackPublications.toList();
    final isLocal = widget.participant is LocalParticipant;

    // 1. Приоритет демонстрации экрана
    for (var pub in pubs) {
      if (pub.source == TrackSource.screenShareVideo &&
          pub.track != null &&
          !pub.muted) {
        newTrack = pub.track as VideoTrack;
        break;
      }
    }

    // 2. Ищем камеру
    if (newTrack == null) {
      for (var pub in pubs) {
        if (pub.source == TrackSource.camera && pub.track != null) {
          if (isLocal || !pub.muted) {
            newTrack = pub.track as VideoTrack;
            break;
          }
        }
      }
    }

    // 3. Запасной вариант (любой доступный видео трек)
    if (newTrack == null) {
      for (var pub in pubs) {
        if (pub.track != null && (isLocal || !pub.muted)) {
          newTrack = pub.track as VideoTrack;
          break;
        }
      }
    }

    if (videoTrack != newTrack) {
      setState(() => videoTrack = newTrack);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(widget.isFocus ? 0 : 16),
        border: widget.participant.isSpeaking && !widget.isFocus
            ? Border.all(color: Colors.greenAccent, width: 3)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          if (videoTrack != null)
            VideoTrackRenderer(
              videoTrack!,
              // 🔥 ИСПРАВЛЕНИЕ: УБРАН key. LiveKit SDK сам управляет текстурами.
              // Принудительная смена ключа уничтожала плеер навсегда!
              fit: widget.isFocus ? VideoViewFit.contain : VideoViewFit.cover,
            )
          else
            const Center(
                child: Icon(Icons.person_rounded,
                    color: Colors.white10, size: 64)),
          Positioned(
            bottom: 10,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8)),
              child: Text(
                widget.participant is LocalParticipant
                    ? "Вы"
                    : (widget.participant.identity ?? "Участник"),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

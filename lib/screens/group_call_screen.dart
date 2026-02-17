import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/livekit_service.dart';

class GroupCallScreen extends StatefulWidget {
  final String roomName;
  final String userName; // Имя для отображения (например, "Папа")
  final String identity; // Уникальный ID (users.id)

  const GroupCallScreen({
    super.key,
    required this.roomName,
    required this.userName,
    required this.identity, // <--- ВОТ ЭТОГО НЕ ХВАТАЛО
  });

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  final _liveKitService = LiveKitService();
  List<Participant> participants = [];

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndConnect();
  }

  Future<void> _checkPermissionsAndConnect() async {
    await [Permission.camera, Permission.microphone].request();
    _connect();
  }

  Future<void> _connect() async {
    try {
      // Передаем все три параметра
      await _liveKitService.joinRoom(
          widget.roomName, widget.identity, widget.userName);

      _liveKitService.room?.addListener(_onRoomUpdate);
      _onRoomUpdate();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Ошибка подключения: $e")),
        );
        Navigator.pop(context);
      }
    }
  }

  void _onRoomUpdate() {
    if (!mounted || _liveKitService.room == null) return;
    setState(() {
      participants = [
        _liveKitService.room!.localParticipant!,
        ..._liveKitService.room!.remoteParticipants.values,
      ];
    });
  }

  @override
  void dispose() {
    _liveKitService.room?.removeListener(_onRoomUpdate);
    _liveKitService.leave();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text("Комната: ${widget.roomName}"),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: participants.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 0.7,
              ),
              itemCount: participants.length,
              itemBuilder: (context, index) {
                return ParticipantWidget(participant: participants[index]);
              },
            ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.red,
        onPressed: () => Navigator.pop(context),
        child: const Icon(Icons.call_end),
      ),
    );
  }
}

// Виджет отдельного участника (Видео + Имя)
class ParticipantWidget extends StatefulWidget {
  final Participant participant;
  const ParticipantWidget({super.key, required this.participant});

  @override
  State<ParticipantWidget> createState() => _ParticipantWidgetState();
}

class _ParticipantWidgetState extends State<ParticipantWidget> {
  VideoTrack? videoTrack;

  @override
  void initState() {
    super.initState();
    widget.participant.addListener(_onParticipantChanged);
    _onParticipantChanged();
  }

  @override
  void didUpdateWidget(covariant ParticipantWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.participant != widget.participant) {
      oldWidget.participant.removeListener(_onParticipantChanged);
      widget.participant.addListener(_onParticipantChanged);
      _onParticipantChanged();
    }
  }

  @override
  void dispose() {
    widget.participant.removeListener(_onParticipantChanged);
    super.dispose();
  }

  void _onParticipantChanged() {
    var allTracks = widget.participant.trackPublications.values;
    var videoPubs = allTracks.where((pub) => pub.kind == TrackType.VIDEO);
    var trackPub = videoPubs.firstWhere(
      (pub) => !pub.muted && pub.subscribed,
      orElse: () => videoPubs.isNotEmpty ? videoPubs.first : null as dynamic,
    );

    if (mounted) {
      setState(() {
        if (trackPub != null && trackPub.track is VideoTrack) {
          videoTrack = trackPub.track as VideoTrack;
        } else {
          videoTrack = null;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        children: [
          if (videoTrack != null)
            VideoTrackRenderer(
              videoTrack!,
              fit: VideoViewFit.cover,
            )
          else
            Container(
              color: Colors.grey.shade900,
              child: const Center(
                child: Icon(Icons.videocam_off, color: Colors.white54),
              ),
            ),
          Positioned(
            bottom: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                widget.participant
                    .identity, // Показываем имя (которое мы передали в токене как identity) или name из метаданных
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

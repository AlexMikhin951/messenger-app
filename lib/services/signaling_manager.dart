import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'api_service.dart';
import '../screens/video_call_screen.dart';
import 'dart:async';
import 'package:local_notifier/local_notifier.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class SignalingManager {
  static final SignalingManager _instance = SignalingManager._internal();
  factory SignalingManager() => _instance;
  SignalingManager._internal();

  final api = ApiService();
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  MediaStream? get localStream => _localStream;
  Function(RTCPeerConnectionState)? onPeerConnectionState;

  List<RTCIceCandidate> _remoteCandidatesQueue = [];
  bool _isNavigating = false;

  // Регулярка для замены локальных IP на IP сервера (если нужно)
  final _internalIpRegex = RegExp(
      r'\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2[0-9]|3[0-1])\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3})\b');

  Map<String, dynamic> _getVideoConstraints(bool isLandscape) {
    double width =
        isLandscape ? 1280 : 720; // Оптимизировал разрешение для стабильности
    double height = isLandscape ? 720 : 1280;

    return {
      'facingMode': 'user',
      'width': {'ideal': width},
      'height': {'ideal': height},
    };
  }

  // --- ИСПРАВЛЕНО: Берем IP из конфига ApiService ---
  Map<String, dynamic> _getIceConfig() {
    // Получаем IP из загруженного конфига
    final String serverIp = api.config?.ip ?? '0.0.0.0';
    print("--- [LOG] ICE Config для IP: $serverIp (TCP Turn) ---");

    return {
      'iceServers': [
        // Используем TCP для обхода блокировок UDP
        {
          'urls': 'turn:$serverIp:3478?transport=tcp',
          'username': 'myuser', // <-- ВАЖНО: Укажите юзера из turnserver.conf
          'credential':
              'mypassword', // <-- ВАЖНО: Укажите пароль из turnserver.conf
        },
        {'urls': 'stun:$serverIp:3478'}, // Наш STUN
        {'urls': 'stun:stun.l.google.com:19302'}, // Резервный STUN
      ],
      'sdpSemantics': 'unified-plan',
      'iceCandidatePoolSize': 10,
    };
  }

  String _optimizeSdp(String sdp) {
    final String serverIp = api.config?.ip ?? '127.0.0.1';

    String fixedSdp = sdp.replaceAll('IN IP4 127.0.0.1', 'IN IP4 0.0.0.0');

    fixedSdp = fixedSdp.replaceAllMapped(_internalIpRegex, (match) {
      return serverIp;
    });

    // Оптимизация битрейта (старт 1000, макс 2500 кбит/с)
    fixedSdp = fixedSdp.replaceAll('a=fmtp:96',
        'a=fmtp:96;x-google-max-bitrate=2500;x-google-min-bitrate=500;x-google-start-bitrate=1000');

    return fixedSdp;
  }

  final Map<String, dynamic> _constraints = {
    'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
    'optional': [],
  };

  void _setConnectionListeners(BuildContext context, String? roomId) {
    _peerConnection?.onIceConnectionState = (RTCIceConnectionState state) {
      print("--- [LOG] ICE State: $state ---");
    };

    _peerConnection?.onConnectionState = (RTCPeerConnectionState state) {
      print("--- [LOG] Connection State: $state ---");
      if (onPeerConnectionState != null) {
        onPeerConnectionState!(state);
      }
    };
  }

  Future<void> _processQueuedCandidates() async {
    if (_peerConnection == null) return;

    if (_peerConnection!.signalingState ==
            RTCSignalingState.RTCSignalingStateHaveRemoteOffer ||
        _peerConnection!.signalingState ==
            RTCSignalingState.RTCSignalingStateStable) {
      for (var candidate in _remoteCandidatesQueue) {
        try {
          await _peerConnection!.addCandidate(candidate);
        } catch (e) {
          print("--- [ERROR] Queue candidate error: $e ---");
        }
      }
      _remoteCandidatesQueue.clear();
    }
  }

  void _setupIceExchange(
      String roomId, bool isCaller, BuildContext context) async {
    final myField =
        isCaller ? 'ice_candidates_caller' : 'ice_candidates_receiver';
    final remoteField =
        isCaller ? 'ice_candidates_receiver' : 'ice_candidates_caller';

    // Используем IP из конфига
    final String serverIp = api.config?.ip ?? '127.0.0.1';
    final Set<String> addedCandidates = {};

    _peerConnection?.onIceCandidate = (RTCIceCandidate candidate) async {
      if (candidate.candidate == null) return;

      String candidateStr = candidate.candidate!
          .replaceAllMapped(_internalIpRegex, (match) => serverIp);

      try {
        final call = await api.pb.collection('calls').getOne(roomId);
        List candidates = List.from(call.data[myField] ?? []);
        candidates.add({
          'candidate': candidateStr,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
        await api.pb
            .collection('calls')
            .update(roomId, body: {myField: candidates});
      } catch (e) {
        print("--- [ERROR] ICE send error: $e ---");
      }
    };

    Future<void> addRemoteCandidates(List? candidates) async {
      if (candidates == null || _peerConnection == null) return;

      for (var data in candidates) {
        String candStr = data['candidate'];
        if (!addedCandidates.contains(candStr)) {
          RTCIceCandidate candidate =
              RTCIceCandidate(candStr, data['sdpMid'], data['sdpMLineIndex']);

          if (_peerConnection!.signalingState !=
                  RTCSignalingState.RTCSignalingStateStable &&
              _peerConnection!.signalingState !=
                  RTCSignalingState.RTCSignalingStateClosed) {
            if (await _peerConnection!.getRemoteDescription() == null) {
              _remoteCandidatesQueue.add(candidate);
            } else {
              await _peerConnection!.addCandidate(candidate);
            }
          } else if (_peerConnection!.signalingState ==
              RTCSignalingState.RTCSignalingStateStable) {
            await _peerConnection!.addCandidate(candidate);
          } else {
            _remoteCandidatesQueue.add(candidate);
          }
          addedCandidates.add(candStr);
        }
      }
    }

    api.pb.collection('calls').subscribe(roomId, (e) {
      if (e.action == 'update') {
        addRemoteCandidates(e.record?.data[remoteField]);
      }
    });

    final initialCall =
        await api.pb.collection('calls').getOne(roomId).catchError((_) => null);
    if (initialCall != null) addRemoteCandidates(initialCall.data[remoteField]);
  }

  Future<String> createCall(String receiverId, RTCVideoRenderer remoteRenderer,
      BuildContext context) async {
    print("--- [LOG] Create Call (Caller) ---");

    _peerConnection = await createPeerConnection(_getIceConfig());
    _setConnectionListeners(context, null);

    List<RTCIceCandidate> earlyCandidates = [];

    _peerConnection?.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate != null) {
        earlyCandidates.add(candidate);
      }
    };

    _peerConnection?.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        scheduleMicrotask(() => remoteRenderer.srcObject = event.streams[0]);
      }
    };

    _localStream
        ?.getTracks()
        .forEach((track) => _peerConnection?.addTrack(track, _localStream!));

    RTCSessionDescription offer =
        await _peerConnection!.createOffer(_constraints);
    String optimizedSdp = _optimizeSdp(offer.sdp!);

    await _peerConnection!
        .setLocalDescription(RTCSessionDescription(optimizedSdp, 'offer'));

    final record = await api.pb.collection('calls').create(body: {
      'caller': api.pb.authStore.record!.id,
      'receiver': receiverId,
      'offer': optimizedSdp,
      'status': 'calling',
      'ice_candidates_caller': [],
      'ice_candidates_receiver': [],
    });

    if (earlyCandidates.isNotEmpty) {
      final String serverIp = api.config?.ip ?? '127.0.0.1';

      List candidatesJson = earlyCandidates
          .map((c) => {
                'candidate': c.candidate!
                    .replaceAllMapped(_internalIpRegex, (match) => serverIp),
                'sdpMid': c.sdpMid,
                'sdpMLineIndex': c.sdpMLineIndex,
              })
          .toList();

      await api.pb
          .collection('calls')
          .update(record.id, body: {'ice_candidates_caller': candidatesJson});
    }

    _setupIceExchange(record.id, true, context);

    bool answerSet = false;
    api.pb.collection('calls').subscribe(record.id, (e) async {
      if (e.action == 'update' &&
          e.record?.data['answer'] != null &&
          !answerSet) {
        if (_peerConnection?.signalingState ==
            RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          answerSet = true;
          try {
            await _peerConnection?.setRemoteDescription(
                RTCSessionDescription(e.record?.data['answer'], 'answer'));
            await _processQueuedCandidates();
          } catch (err) {
            print("--- [ERROR] Answer error: $err ---");
            answerSet = false;
          }
        }
      }
    });

    return record.id;
  }

  Future<void> updateVideoOrientation(
      RTCVideoRenderer local, bool isLandscape) async {
    if (_localStream == null) return;
    try {
      MediaStream newStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': _getVideoConstraints(isLandscape),
      });

      var newVideoTrack = newStream.getVideoTracks().first;
      await _replaceVideoTrack(newVideoTrack);
      _localStream?.getTracks().forEach((track) => track.stop());
      _localStream = newStream;
      local.srcObject = _localStream;
    } catch (e) {
      print("--- [ERROR] Orientation update error: $e ---");
    }
  }

  Future<void> joinCall(String roomId, RTCVideoRenderer remoteRenderer,
      BuildContext context) async {
    print("--- [LOG] Join Call (Receiver) ---");

    _remoteCandidatesQueue.clear();
    _peerConnection = await createPeerConnection(_getIceConfig());
    _setConnectionListeners(context, roomId);

    _peerConnection?.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        scheduleMicrotask(() => remoteRenderer.srcObject = event.streams[0]);
      }
    };

    _localStream
        ?.getTracks()
        .forEach((track) => _peerConnection?.addTrack(track, _localStream!));

    _setupIceExchange(roomId, false, context);

    final callData = await api.pb.collection('calls').getOne(roomId);

    if (_peerConnection?.signalingState !=
        RTCSignalingState.RTCSignalingStateStable) {
      await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(callData.data['offer'], 'offer'));

      await _processQueuedCandidates();

      RTCSessionDescription answer =
          await _peerConnection!.createAnswer(_constraints);
      String optimizedSdp = _optimizeSdp(answer.sdp!);

      await _peerConnection!
          .setLocalDescription(RTCSessionDescription(optimizedSdp, 'answer'));

      await api.pb.collection('calls').update(roomId,
          body: {'answer': optimizedSdp, 'status': 'connected'});
    }
  }

  /// Переключение на захват экрана и обратно
  /// ИСПРАВЛЕННАЯ ВЕРСИЯ ДЛЯ WEB и WINDOWS
  Future<void> switchScreenShare(RTCVideoRenderer localRenderer, bool enable,
      {BuildContext? context}) async {
    try {
      MediaStream? newStream;
      if (enable) {
        print("--- [LOG] Запрос на захват экрана ---");

        if (kIsWeb) {
          // --- ЛОГИКА ДЛЯ WEB ---
          // В вебе браузер сам показывает диалог выбора окна/вкладки
          newStream = await navigator.mediaDevices.getDisplayMedia({
            'video': true,
            'audio': false,
          });
        } else if (WebRTC.platformIsWindows || WebRTC.platformIsMacOS) {
          // --- ЛОГИКА ДЛЯ WINDOWS/MAC ---
          if (context != null) {
            final sources = await desktopCapturer
                .getSources(types: [SourceType.Window, SourceType.Screen]);

            DesktopCapturerSource? selectedSource =
                await showDialog<DesktopCapturerSource>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text("Выберите окно или экран"),
                content: SizedBox(
                  width: double.maxFinite,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: sources.length,
                    itemBuilder: (context, index) => ListTile(
                      title: Text(sources[index].name),
                      leading: sources[index].thumbnail != null
                          ? Image.memory(sources[index].thumbnail!, width: 50)
                          : const Icon(Icons.desktop_windows),
                      onTap: () => Navigator.pop(context, sources[index]),
                    ),
                  ),
                ),
              ),
            );

            if (selectedSource == null) return;

            newStream = await navigator.mediaDevices.getDisplayMedia({
              'video': {
                'deviceId': {'exact': selectedSource.id},
                'mandatory': {'frameRate': 20.0}
              },
              'audio': false,
            });
          }
        } else {
          // Для Android/iOS
          if (WebRTC.platformIsAndroid) await Helper.requestCapturePermission();
          newStream = await navigator.mediaDevices.getDisplayMedia({
            'video': {'width': 1280, 'height': 720, 'frameRate': 20},
            'audio': false,
          });
        }
      } else {
        print("--- [LOG] Возврат к камере ---");
        // При возврате проверяем ориентацию
        final isLandscape = context != null &&
            MediaQuery.of(context).orientation == Orientation.landscape;

        newStream = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': _getVideoConstraints(isLandscape),
        });
      }

      if (newStream != null && newStream.getVideoTracks().isNotEmpty) {
        await _replaceVideoTrack(newStream.getVideoTracks().first);
        _localStream?.getTracks().forEach((track) => track.stop());
        _localStream = newStream;
        localRenderer.srcObject = _localStream;
      }
    } catch (e) {
      print("--- [ERROR] Ошибка при переключении источника: $e ---");
    }
  }

  /// Замена видео-трека "на лету" без разрыва соединения
  Future<void> _replaceVideoTrack(MediaStreamTrack newTrack) async {
    if (_peerConnection == null ||
        _peerConnection!.signalingState ==
            RTCSignalingState.RTCSignalingStateClosed) return;
    try {
      var transceivers = await _peerConnection!.getTransceivers();
      bool trackReplaced = false;
      for (var transceiver in transceivers) {
        if (transceiver.sender.track?.kind == 'video') {
          await transceiver.sender.replaceTrack(newTrack);
          trackReplaced = true;
          print("--- [LOG] Трек заменен через Transceiver ---");
          break;
        }
      }
      if (!trackReplaced) {
        var senders = await _peerConnection!.getSenders();
        for (var sender in senders) {
          if (sender.track?.kind == 'video') {
            await sender.replaceTrack(newTrack);
            print("--- [LOG] Трек заменен через Sender ---");
            break;
          }
        }
      }
    } catch (e) {
      print("--- [ERROR] Не удалось заменить видео-трек: $e ---");
    }
  }

  /// Глобальный слушатель входящих вызовов
  void initCallListener(BuildContext context) {
    if (api.pb.authStore.record == null) return;
    final String myId = api.pb.authStore.record!.id;
    api.pb
        .collection('calls')
        .unsubscribe('*')
        .catchError((_) => null)
        .then((_) {
      try {
        api.pb.collection('calls').subscribe('*', (e) {
          if (!context.mounted) return;
          if (e.action == 'create') {
            final data = e.record!.data;
            if (data['receiver'] == myId && data['status'] == 'calling') {
              print("--- [LOG] Входящий звонок! ---");
              Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => VideoCallScreen(
                            receiverId: data['caller'],
                            isIncoming: true,
                            roomId: e.record!.id,
                          )));
            }
          }
        });
      } catch (err) {
        print("--- [!] Ошибка Realtime: $err ---");
      }
    });
  }

  Timer? _heartbeatTimer;

  void startHeartbeat() {
    _heartbeatTimer?.cancel();

    Future<void> sendPulse() async {
      final user = api.pb.authStore.record;
      if (user != null) {
        try {
          await api.pb.collection('users').update(user.id, body: {
            'last_seen': DateTime.now().toUtc().toIso8601String(),
            'is_online': true,
          });
        } catch (e) {
          print("--- [Heartbeat] Ошибка: $e ---");
        }
      }
    }

    sendPulse();
    _heartbeatTimer =
        Timer.periodic(const Duration(seconds: 7), (timer) => sendPulse());
  }

  /// Получение доступа к медиа-устройствам с учетом ориентации
  Future<void> openUserMedia(
      RTCVideoRenderer local, RTCVideoRenderer remote, bool isLandscape) async {
    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': _getVideoConstraints(isLandscape),
      });
      local.srcObject = _localStream;
    } catch (e) {
      print("--- [ERROR] Camera access error: $e ---");
    }
  }

  Future<void> hangUp(String? roomId) async {
    onPeerConnectionState = null;
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream = null;
    await _peerConnection?.close();
    _peerConnection = null;

    if (roomId != null) {
      api.pb.collection('calls').unsubscribe(roomId).catchError((_) => null);
      try {
        await api.pb.collection('calls').delete(roomId);
      } catch (_) {}
    }
  }

  void startListeningNotifications() async {
    // В вебе работа с SSE может блокироваться CORS, но код оставляем валидным
    final user = ApiService().pb.authStore.model;
    if (user == null) return;

    final String phone =
        user.getStringValue("username").replaceAll(RegExp(r'\D'), '');
    final String topic = "family_msg_$phone";

    try {
      final request =
          http.Request("GET", Uri.parse("https://ntfy.sh/$topic/sse"));
      final client = http.Client();
      final response = await client.send(request);

      print("--- [LOG] Подключено к ntfy: $topic ---");

      response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final trimmedLine = line.trim();

        if (!trimmedLine.startsWith('data:')) return;

        try {
          final int jsonStartIndex = trimmedLine.indexOf('{');
          if (jsonStartIndex == -1) return;

          final String jsonPart = trimmedLine.substring(jsonStartIndex);
          final data = jsonDecode(jsonPart);

          if (data['event'] == 'keepalive') return;

          print("--- [LOG] Валидное уведомление: ${data['event']} ---");

          // Вызов уведомления
          if (data['title'] != null && data['message'] != null) {
            _showWindowsNotification(data['title'], data['message']);
          }
        } catch (e) {
          print("--- [ERROR] Ошибка парсинга: $e | Строка: $trimmedLine ---");
        }
      }, onError: (e) {
        print("--- [ERROR] Ошибка стрима SSE: $e ---");
        _reconnect(() => startListeningNotifications());
      });
    } catch (e) {
      print("--- [ERROR] Не удалось подключиться к ntfy: $e ---");
    }
  }

  void _reconnect(VoidCallback callback) {
    Future.delayed(const Duration(seconds: 5), callback);
  }

  // ОБНОВЛЕННЫЙ МЕТОД УВЕДОМЛЕНИЙ
  void _showWindowsNotification(String title, String body) {
    if (kIsWeb) return;
    try {
      LocalNotification(title: title, body: body).show();
    } catch (e) {
      print("Notify Error: $e");
    }
  }

  Future<void> checkActiveCalls(BuildContext context) async {
    if (_isNavigating) return;

    try {
      final myId = api.pb.authStore.record?.id;
      if (myId == null) return;

      final records = await api.pb.collection('calls').getList(
            page: 1,
            perPage: 1,
            filter: 'receiver = "$myId" && status = "calling"',
            sort: '-created',
          );

      if (records.items.isNotEmpty) {
        final call = records.items.first;

        bool isAlreadyOnCall = false;
        Navigator.popUntil(context, (route) {
          if (route.settings.name == '/call') isAlreadyOnCall = true;
          return true;
        });

        if (!isAlreadyOnCall) {
          _isNavigating = true;

          await Navigator.pushNamed(
            context,
            '/call',
            arguments: {
              'receiverId': call.getStringValue('caller'),
              'isIncoming': true,
              'roomId': call.id,
            },
          );

          _isNavigating = false;
        }
      }
    } catch (e) {
      _isNavigating = false;
      debugPrint("Ошибка проверки активных звонков: $e");
    }
  }
}

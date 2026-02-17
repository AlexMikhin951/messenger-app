import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'api_service.dart';
import '../screens/video_call_screen.dart';
import 'dart:async';
import 'package:local_notifier/local_notifier.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_v2ray/flutter_v2ray.dart';

class SignalingManager {
  static final SignalingManager _instance = SignalingManager._internal();
  factory SignalingManager() => _instance;
  SignalingManager._internal();

  final api = ApiService();

  // 1. Создаем переменную для хранения статуса
  String _v2rayState = "DISCONNECTED";

  // 2. Инициализируем V2Ray с колбэком, который обновляет нашу переменную
  late final FlutterV2ray _v2ray = FlutterV2ray(
    onStatusChanged: (V2RayStatus status) {
      _v2rayState = status.state; // Сохраняем состояние (например, "CONNECTED")
      print("--- [V2Ray] Статус изменился на: $_v2rayState ---");
    },
  );
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
    // В режиме Варианта Б (Reality Stealth) мы заставляем WebRTC
    // подключаться к локальному прокси-порту V2Ray.
    // Обычно V2Ray на Android/iOS создает VPN-интерфейс,
    // поэтому 127.0.0.1 — это "вход" в твой защищенный туннель.

    const String localhost = '127.0.0.1';
    print("--- [LOG] ICE Config: Маршрутизация через туннель (localhost) ---");

    return {
      'iceServers': [
        {
          // Форсируем TCP транспорт, так как Reality лучше всего работает с ним,
          // и это позволяет полностью скрыть UDP-трафик звонка.
          'urls': 'turn:$localhost:3478?transport=tcp',
          'username': 'myuser',
          'credential': 'mypassword',
        },
        {'urls': 'stun:$localhost:3478?transport=tcp'},
      ],
      'sdpSemantics': 'unified-plan',
      'iceCandidatePoolSize': 10,
    };
  }

  String _optimizeSdp(String sdp) {
    List<String> lines = sdp.split('\n');
    List<String> filteredLines = [];

    for (String line in lines) {
      // 1. Убираем всё, что связано с UDP (нам нужен только TCP внутри туннеля)
      if (line.contains('udp') || line.contains('UDP')) {
        continue;
      }

      // 2. Если строка содержит IP-адрес, меняем его на локальный вход туннеля
      if (line.contains('IN IP4')) {
        // Заменяем любой IP на 127.0.0.1
        line = line.replaceAllMapped(
            RegExp(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'),
            (match) => '127.0.0.1');
      }

      // 3. Добавляем настройки битрейта для видео (важно для стабильности в туннеле)
      if (line.contains('a=fmtp:96')) {
        // x-google-max-bitrate=1500 (1.5 мбит/с) — золотая середина для мобильного 4G через прокси
        line =
            '$line;x-google-max-bitrate=1500;x-google-min-bitrate=500;x-google-start-bitrate=800';
      }

      filteredLines.add(line);
    }

    // Собираем обратно
    return filteredLines.join('\n');
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

  Future<void> initSecureTunnel() async {
    print("--- [V2Ray] Инициализация защищенного туннеля... ---");

    // Запрашиваем разрешение на VPN (Android/iOS спросит пользователя)
    if (!await _v2ray.requestPermission()) {
      print("--- [ERROR] Пользователь отклонил разрешение на VPN ---");
      return;
    }

    // Твой конфиг VLESS Reality (Client Config)
    // ВНИМАНИЕ: Замени данные на свои реальные из панели 3X-UI
    final String config = """
    {
      "log": {
        "loglevel": "warning"
      },
      "inbounds": [
        {
          "port": 10808,
          "listen": "127.0.0.1",
          "protocol": "socks",
          "settings": {
            "udp": true
          }
        }
      ],
      "outbounds": [
        {
          "protocol": "vless",
          "settings": {
            "vnext": [
              {
                "address": "ТВОЙ_IP_СЕРВЕРА", 
                "port": 443,
                "users": [
                  {
                    "id": "ТВОЙ_UUID",
                    "encryption": "none",
                    "flow": "xtls-rprx-vision"
                  }
                ]
              }
            ]
          },
          "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
              "show": false,
              "fingerprint": "chrome",
              "serverName": "vk.com", 
              "publicKey": "ТВОЙ_PUBLIC_KEY",
              "shortId": "ТВОЙ_SHORT_ID",
              "spiderX": "/"
            }
          },
          "tag": "proxy"
        }
      ]
    }
    """;

    try {
      await _v2ray.startV2Ray(
        remark: "Secure VK Tunnel",
        config: config,
        proxyOnly: false, // false = режим VPN (весь трафик перехватывается)
      );
      print("--- [V2Ray] Команда на запуск отправлена ---");
    } catch (e) {
      print("--- [ERROR] Ошибка запуска ядра V2Ray: $e ---");
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

  Future<String?> createCall(
      String receiverId,
      RTCVideoRenderer localRenderer,
      RTCVideoRenderer remoteRenderer,
      BuildContext context,
      bool isLandscape) async {
    print("--- [LOG] Create Call (Stealth Mode: V2Ray/Reality) ---");

    try {
      // 1. Проверка состояния туннеля через нашу внутреннюю переменную
      // Вариант Б: звонок не начнется, пока "броня" не активна
      if (_v2rayState != "CONNECTED") {
        print(
            "--- [WARNING] Внимание: V2Ray не подключен (Статус: $_v2rayState) ---");
        // Здесь можно выбросить ошибку или вызвать метод подключения
      }

      // 2. Инициализация камеры и микрофона
      await openUserMedia(localRenderer, remoteRenderer, isLandscape);

      if (_localStream == null) {
        print("--- [ERROR] Не удалось получить доступ к медиа ---");
        return null;
      }

      // 3. Создание PeerConnection с ICE-конфигом на localhost
      // Это заставляет WebRTC искать TURN-сервер внутри туннеля
      _peerConnection = await createPeerConnection(_getIceConfig());
      _setConnectionListeners(context, null);

      List<RTCIceCandidate> earlyCandidates = [];

      // Собираем кандидатов локально
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

      // 4. Привязка локального видео-потока к соединению
      _localStream!.getTracks().forEach((track) {
        _peerConnection?.addTrack(track, _localStream!);
      });

      // 5. Создание Offer и "стелс-оптимизация" SDP
      RTCSessionDescription offer =
          await _peerConnection!.createOffer(_constraints);

      // Вырезаем реальные IP, заменяя их на 127.0.0.1 и форсируя TCP
      String optimizedSdp = _optimizeSdp(offer.sdp!);

      await _peerConnection!
          .setLocalDescription(RTCSessionDescription(optimizedSdp, 'offer'));

      // 6. Регистрация звонка в PocketBase
      // Запрос идет через туннель, провайдер видит "запрос к VK"
      final record = await api.pb.collection('calls').create(body: {
        'caller': api.pb.authStore.record!.id,
        'receiver': receiverId,
        'offer': optimizedSdp, // Транслируем только безопасный SDP
        'status': 'calling',
        'ice_candidates_caller': [],
        'ice_candidates_receiver': [],
      });

      // 7. Маскировка и отправка ICE-кандидатов
      if (earlyCandidates.isNotEmpty) {
        // Подменяем все IP на адрес локального входа в туннель
        const String stealthIp = '127.0.0.1';

        List candidatesJson = earlyCandidates
            .map((c) => {
                  'candidate': c.candidate!
                      .replaceAllMapped(_internalIpRegex, (match) => stealthIp),
                  'sdpMid': c.sdpMid,
                  'sdpMLineIndex': c.sdpMLineIndex,
                })
            .toList();

        await api.pb
            .collection('calls')
            .update(record.id, body: {'ice_candidates_caller': candidatesJson});
      }

      // 8. Запуск слушателя для обмена кандидатами
      _setupIceExchange(record.id, true, context);

      // 9. Подписка на Answer (ответ от получателя)
      bool answerSet = false;
      api.pb.collection('calls').subscribe(record.id, (e) async {
        if (e.action == 'update' &&
            e.record?.data['answer'] != null &&
            !answerSet) {
          if (_peerConnection?.signalingState ==
              RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
            answerSet = true;
            try {
              print(
                  "--- [LOG] Ответ получен. Устанавливаем защищенную сессию... ---");
              await _peerConnection?.setRemoteDescription(
                  RTCSessionDescription(e.record?.data['answer'], 'answer'));

              // Применяем накопленные удаленные кандидаты
              await _processQueuedCandidates();
            } catch (err) {
              print("--- [ERROR] Ошибка дешифровки/установки Answer: $err ---");
              answerSet = false;
            }
          }
        }
      });

      return record.id;
    } catch (e) {
      print("--- [ERROR] Критическая ошибка createCall (Stealth): $e ---");
      return null;
    }
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

  Future<void> joinCall(
      String roomId,
      RTCVideoRenderer localRenderer,
      RTCVideoRenderer remoteRenderer,
      BuildContext context,
      bool isLandscape) async {
    print("--- [LOG] Join Call (Receiver) ---");

    try {
      // 1. Сначала открываем медиа (ОБЯЗАТЕЛЬНО)
      await openUserMedia(localRenderer, remoteRenderer, isLandscape);

      if (_localStream == null) {
        print("--- [ERROR] Не удалось инициализировать камеру/микрофон ---");
        return;
      }

      _remoteCandidatesQueue.clear();

      // 2. Создаем PeerConnection
      _peerConnection = await createPeerConnection(_getIceConfig());
      _setConnectionListeners(context, roomId);

      _peerConnection?.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          scheduleMicrotask(() => remoteRenderer.srcObject = event.streams[0]);
        }
      };

      // 3. Добавляем свои треки
      _localStream!.getTracks().forEach((track) {
        _peerConnection?.addTrack(track, _localStream!);
      });

      // 4. Запускаем обмен кандидатами
      _setupIceExchange(roomId, false, context);

      // 5. Получаем данные о звонке (Offer)
      final callData = await api.pb.collection('calls').getOne(roomId);

      // 6. Устанавливаем RemoteDescription (Offer от звонящего)
      // Это критически важно сделать ПЕРЕД созданием Answer
      if (_peerConnection?.signalingState !=
          RTCSignalingState.RTCSignalingStateStable) {
        print("--- [LOG] Устанавливаем Offer от звонящего... ---");
        await _peerConnection!.setRemoteDescription(
            RTCSessionDescription(callData.data['offer'], 'offer'));

        // Теперь, когда Offer установлен, можно безопасно добавить кандидатов
        await _processQueuedCandidates();

        // 7. Создаем свой Answer
        RTCSessionDescription answer =
            await _peerConnection!.createAnswer(_constraints);
        String optimizedSdp = _optimizeSdp(answer.sdp!);
        await _peerConnection!
            .setLocalDescription(RTCSessionDescription(optimizedSdp, 'answer'));

        // 8. Отправляем Answer в базу
        await api.pb.collection('calls').update(roomId,
            body: {'answer': optimizedSdp, 'status': 'connected'});
        print("--- [LOG] Answer отправлен, соединение установлено ---");
      }
    } catch (e) {
      print("--- [ERROR] Ошибка в joinCall: $e ---");
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
        Timer.periodic(const Duration(seconds: 5), (timer) => sendPulse());
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

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb; // Добавлено для проверки Web
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

  // Геттер для управления локальным потоком из UI
  MediaStream? get localStream => _localStream;
  Function(RTCPeerConnectionState)? onPeerConnectionState;

  // Очередь для ICE-кандидатов, пришедших до установки Remote Description
  List<RTCIceCandidate> _remoteCandidatesQueue = [];

  // Добавь флаг, чтобы не открывать звонок дважды
  bool _isNavigating = false;

  // Регулярка для фильтрации и замены локальных IP на IP сервера (динамический)
  final _internalIpRegex = RegExp(
      r'\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2[0-9]|3[0-1])\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3})\b');

  /// Вспомогательный метод для получения настроек видео в зависимости от ориентации
  Map<String, dynamic> _getVideoConstraints(bool isLandscape) {
    // Если горизонтально: 1920x1080. Если вертикально: 1080x1920.
    double width = isLandscape ? 1920 : 1080;
    double height = isLandscape ? 1080 : 1920;
    double ratio = width / height;

    print(
        "--- [LOG] Констрейнты видео: ${width.toInt()}x${height.toInt()} (ratio: ${ratio.toStringAsFixed(2)}) ---");

    return {
      'facingMode': 'user',
      'width': {'ideal': width},
      'height': {'ideal': height},
      'aspectRatio': ratio,
    };
  }

  /// Генерация конфигурации ICE на основе текущего хоста PocketBase
  Map<String, dynamic> _getIceConfig() {
    // Для Web иногда baseUrl может быть относительным, но PocketBase обычно дает полный URL
    final uri = Uri.parse(api.pb.baseUrl);
    final String currentIp = uri.host;

    print("--- [LOG] Конфигурация ICE для IP: $currentIp ---");
    return {
      'iceServers': [
        {'urls': 'stun:$currentIp:3478'},
        {
          'urls': 'turn:$currentIp:3478',
          'username': 'family',
          'credential': 'strongpassword123',
        },
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
      'iceCandidatePoolSize': 10,
    };
  }

  /// Оптимизация SDP: подмена локальных адресов на внешний IP сервера + битрейт
  String _optimizeSdp(String sdp) {
    final uri = Uri.parse(api.pb.baseUrl);
    final String currentIp = uri.host;

    String fixedSdp = sdp.replaceAll('IN IP4 127.0.0.1', 'IN IP4 0.0.0.0');

    fixedSdp = fixedSdp.replaceAllMapped(_internalIpRegex, (match) {
      print(
          "--- [LOG] SDP: Замена внутреннего IP ${match.group(0)} -> $currentIp ---");
      return currentIp;
    });

    // Форсируем высокий битрейт для HD качества
    fixedSdp = fixedSdp.replaceAll('a=fmtp:96',
        'a=fmtp:96;x-google-max-bitrate=3500;x-google-min-bitrate=1000;x-google-start-bitrate=2000');

    return fixedSdp;
  }

  final Map<String, dynamic> _constraints = {
    'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
    'optional': [],
  };

  void _setConnectionListeners(BuildContext context, String? roomId) {
    // 1. Проверки состояния ICE (транспорт)
    _peerConnection?.onIceConnectionState = (RTCIceConnectionState state) {
      print("--- [LOG] Состояние ICE: $state ---");
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        print("--- [LOG] Внимание: Соединение нестабильно ---");
      }
    };

    // 2. Статус соединения
    _peerConnection?.onConnectionState = (RTCPeerConnectionState state) {
      print("--- [LOG] Статус соединения изменился: $state ---");

      // Вызываем колбэк для экрана
      if (onPeerConnectionState != null) {
        onPeerConnectionState!(state);
      }
    };
  }

  /// Обработка накопившихся ICE-кандидатов после установки SDP
  Future<void> _processQueuedCandidates() async {
    if (_peerConnection == null) return;

    if (_peerConnection!.signalingState ==
            RTCSignalingState.RTCSignalingStateHaveRemoteOffer ||
        _peerConnection!.signalingState ==
            RTCSignalingState.RTCSignalingStateStable) {
      print(
          "--- [LOG] Обработка очереди ICE (${_remoteCandidatesQueue.length} шт.) ---");
      for (var candidate in _remoteCandidatesQueue) {
        try {
          await _peerConnection!.addCandidate(candidate);
        } catch (e) {
          print("--- [ERROR] Ошибка добавления из очереди: $e ---");
        }
      }
      _remoteCandidatesQueue.clear();
    }
  }

  /// Логика обмена ICE-кандидатами через PocketBase
  void _setupIceExchange(
      String roomId, bool isCaller, BuildContext context) async {
    final myField =
        isCaller ? 'ice_candidates_caller' : 'ice_candidates_receiver';
    final remoteField =
        isCaller ? 'ice_candidates_receiver' : 'ice_candidates_caller';

    final uri = Uri.parse(api.pb.baseUrl);
    final String currentIp = uri.host;
    final Set<String> addedCandidates = {};

    _peerConnection?.onIceCandidate = (RTCIceCandidate candidate) async {
      if (candidate.candidate == null) return;

      String candidateStr = candidate.candidate!
          .replaceAllMapped(_internalIpRegex, (match) => currentIp);

      try {
        // Используем транзакционную логику: получаем актуальный список и пушим
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
        print("--- [LOG] Локальный ICE отправлен в базу ---");
      } catch (e) {
        print("--- [ERROR] Ошибка отправки ICE: $e ---");
      }
    };

    // Внутренняя функция обработки удаленных кандидатов
    Future<void> addRemoteCandidates(List? candidates) async {
      if (candidates == null || _peerConnection == null) return;

      for (var data in candidates) {
        String candStr = data['candidate'];
        if (!addedCandidates.contains(candStr)) {
          RTCIceCandidate candidate =
              RTCIceCandidate(candStr, data['sdpMid'], data['sdpMLineIndex']);

          // Проверяем, можно ли добавить кандидата сейчас
          if (_peerConnection!.signalingState !=
                  RTCSignalingState.RTCSignalingStateStable &&
              _peerConnection!.signalingState !=
                  RTCSignalingState.RTCSignalingStateClosed) {
            // Если Offer еще не установлен — в очередь
            if (await _peerConnection!.getRemoteDescription() == null) {
              _remoteCandidatesQueue.add(candidate);
              print("--- [LOG] ICE в очереди (ждем setRemoteDescription) ---");
            } else {
              try {
                await _peerConnection!.addCandidate(candidate);
                print("--- [LOG] Удаленный ICE успешно добавлен ---");
              } catch (e) {
                print("--- [ERROR] Ошибка addCandidate: $e ---");
              }
            }
          } else if (_peerConnection!.signalingState ==
              RTCSignalingState.RTCSignalingStateStable) {
            // Если уже Stable — добавляем сразу
            await _peerConnection!.addCandidate(candidate);
          } else {
            _remoteCandidatesQueue.add(candidate);
          }
          addedCandidates.add(candStr);
        }
      }
    }

    // Подписка на обновления
    api.pb.collection('calls').subscribe(roomId, (e) {
      if (e.action == 'update') {
        addRemoteCandidates(e.record?.data[remoteField]);
      }
    });

    // Проверка начальных кандидатов
    final initialCall =
        await api.pb.collection('calls').getOne(roomId).catchError((_) => null);
    if (initialCall != null) addRemoteCandidates(initialCall.data[remoteField]);
  }

  /// Создание звонка (Caller)
  Future<String> createCall(String receiverId, RTCVideoRenderer remoteRenderer,
      BuildContext context) async {
    print("--- [LOG] Инициализация звонка (Caller) ---");

    _peerConnection = await createPeerConnection(_getIceConfig());
    _setConnectionListeners(context, null);

    // Список для сбора кандидатов, которые вылетят ДО создания записи в БД
    List<RTCIceCandidate> earlyCandidates = [];

    _peerConnection?.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate != null) {
        print("--- [LOG] Пойман ранний ICE кандидат ---");
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

    // Теперь создаем запись в базе
    final record = await api.pb.collection('calls').create(body: {
      'caller': api.pb.authStore.record!.id,
      'receiver': receiverId,
      'offer': optimizedSdp,
      'status': 'calling',
      'ice_candidates_caller': [],
      'ice_candidates_receiver': [],
    });

    print(
        "--- [LOG] Запись создана: ${record.id}. Сохраняем ранние кандидаты: ${earlyCandidates.length} ---");

    // Отправляем ранние кандидаты
    if (earlyCandidates.isNotEmpty) {
      final uri = Uri.parse(api.pb.baseUrl);
      final String currentIp = uri.host;

      List candidatesJson = earlyCandidates
          .map((c) => {
                'candidate': c.candidate!
                    .replaceAllMapped(_internalIpRegex, (match) => currentIp),
                'sdpMid': c.sdpMid,
                'sdpMLineIndex': c.sdpMLineIndex,
              })
          .toList();

      await api.pb
          .collection('calls')
          .update(record.id, body: {'ice_candidates_caller': candidatesJson});
    }

    // Запускаем стандартный обмен
    _setupIceExchange(record.id, true, context);

    // Подписка на Answer
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
      print(
          "--- [LOG] Перенастройка камеры под ориентацию: ${isLandscape ? 'Landscape' : 'Portrait'} ---");

      MediaStream newStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': _getVideoConstraints(isLandscape),
      });

      var newVideoTrack = newStream.getVideoTracks().first;
      await _replaceVideoTrack(newVideoTrack);
      _localStream?.getTracks().forEach((track) => track.stop());

      _localStream = newStream;
      local.srcObject = _localStream;

      print("--- [LOG] Ориентация потока успешно обновлена ---");
    } catch (e) {
      print("--- [ERROR] Не удалось обновить ориентацию: $e ---");
    }
  }

  /// Присоединение к звонку (Receiver)
  Future<void> joinCall(String roomId, RTCVideoRenderer remoteRenderer,
      BuildContext context) async {
    print("--- [LOG] Присоединение к звонку (Receiver) ---");

    _remoteCandidatesQueue.clear();

    _peerConnection = await createPeerConnection(_getIceConfig());
    _setConnectionListeners(context, roomId);

    _peerConnection?.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        print("--- [LOG] ВИДЕОПОТОК ПОЛУЧЕН (Receiver) ---");
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
      print("--- [LOG] Установка Remote Offer ---");

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

      print(
          "--- [LOG] Answer установлен и отправлен. Состояние: ${_peerConnection?.signalingState} ---");
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
      print(
          "--- [LOG] Камера включена. Режим: ${isLandscape ? 'Landscape' : 'Portrait'} ---");
    } catch (e) {
      print("--- [ERROR] Ошибка доступа к камере: $e ---");
    }
  }

  /// Завершение звонка и очистка ресурсов
  Future<void> hangUp(String? roomId) async {
    print("--- [LOG] Завершение звонка... ---");

    onPeerConnectionState = null;

    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream = null;

    await _peerConnection?.close();
    _peerConnection = null;

    if (roomId != null) {
      api.pb.collection('calls').unsubscribe(roomId).catchError((_) => null);
      await api.pb.collection('calls').delete(roomId).catchError((_) => null);
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
    // В Вебе local_notifier может не работать или требовать инициализации,
    // которую мы не можем гарантировать. Просто логируем.
    if (kIsWeb) {
      print("--- [WEB NOTIFICATION] $title: $body ---");
      return;
    }

    // Для Desktop
    try {
      LocalNotification notification = LocalNotification(
        title: title,
        body: body,
        silent: false,
      );
      notification.show();
    } catch (e) {
      print("Ошибка показа уведомления: $e");
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

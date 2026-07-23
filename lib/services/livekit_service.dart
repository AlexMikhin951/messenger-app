import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'api_service.dart';

class LiveKitService {
  LiveKitService(this._api);

  final ApiService _api;

  // ВАЖНО: Замените на ваши настоящие ключи с сервера LiveKit
  static const String _apiKey = "CK_FamilyChat_User";
  static const String _apiSecret = "CS_9v2qXwL5mP1zQ8r5wL2jK6hF0dG3s";

  String _generateToken(String roomName, String participantIdentity) {
    final now = DateTime.now();
    final exp = now.add(const Duration(hours: 2));
    final jwt = JWT(
      {
        "sub": participantIdentity,
        "name": participantIdentity,
        "iss": _apiKey,
        "nbf": now.millisecondsSinceEpoch ~/ 1000,
        "exp": exp.millisecondsSinceEpoch ~/ 1000,
        "video": {
          "room": roomName,
          "roomJoin": true,
          "canPublish": true,
          "canSubscribe": true,
          "hidden": false,
        },
      },
    );
    return jwt.sign(SecretKey(_apiSecret));
  }

  Future<Room?> joinGroupCall(
      String roomName, String participantIdentity) async {
    try {
      final currentIp = _api.config?.ip;
      if (currentIp == null || currentIp.isEmpty) {
        throw Exception("Ошибка: IP сервера неизвестен. Проверьте ApiService.");
      }
      final String wsUrl = "ws://$currentIp:7880";
      debugPrint("🔗 [LiveKit] Подключение к групповому звонку: $wsUrl");

      String token = _generateToken(roomName, participantIdentity);
      final roomOptions = const RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultVideoPublishOptions: VideoPublishOptions(
          simulcast: true,
          videoCodec: 'VP8',
        ),
        defaultAudioPublishOptions: AudioPublishOptions(
          dtx: true,
        ),
      );

      final room = Room();
      await room.connect(
        wsUrl,
        token,
        roomOptions: roomOptions,
        // 🔥 ИСПРАВЛЕНИЕ: Убрали fastConnectOptions, чтобы избежать двойного старта камеры
      );
      debugPrint("✅ [LiveKit] Успешный вход в комнату: ${room.name}");
      return room;
    } catch (e) {
      debugPrint("❌ [LiveKit] Ошибка подключения: $e");
      rethrow;
    }
  }
}

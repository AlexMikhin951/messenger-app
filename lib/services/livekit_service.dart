import 'package:livekit_client/livekit_client.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'api_service.dart'; // Сервис, где хранится IP сервера

class LiveKitService {
  // ИСПОЛЬЗУЕМ ВАШИ НАСТОЯЩИЕ КЛЮЧИ С СЕРВЕРА
  static const String _apiKey = "CK_FamilyChat_User";
  static const String _apiSecret = "CS_9v2qXwL5mP1zQ8r5wL2jK6hF0dG3s";

  /// Генерирует токен для входа (Локально)
  String _generateToken(String roomName, String participantName) {
    // Токен живет 2 часа
    final now = DateTime.now();
    final exp = now.add(const Duration(hours: 2));

    final jwt = JWT(
      {
        "sub": participantName, // Уникальный идентификатор (identity)
        "name": participantName, // Имя пользователя для UI
        "iss": _apiKey,
        "nbf": now.millisecondsSinceEpoch ~/ 1000,
        "exp": exp.millisecondsSinceEpoch ~/ 1000,
        "video": {
          "room": roomName,
          "roomJoin": true,
          "canPublish": true,
          "canSubscribe": true,
          // Разрешаем скрытые подписки (важно для оптимизации)
          "hidden": false,
        },
      },
    );

    return jwt.sign(SecretKey(_apiSecret));
  }

  /// Главный метод подключения
  Future<Room?> joinGroupCall(String roomName, String participantName) async {
    try {
      // 1. Достаем IP из ApiService
      // ApiService к этому моменту УЖЕ должен быть инициализирован
      final api = ApiService();
      final currentIp = api.config?.ip;

      if (currentIp == null || currentIp.isEmpty) {
        throw Exception(
            "Ошибка: IP сервера неизвестен. Нет связи с ApiService.");
      }

      // 2. Формируем URL
      // Используем ws:// (не wss), так как у нас голый IP без домена/SSL для порта 7880
      final String wsUrl = "ws://$currentIp:7880";

      print("🔗 [LiveKit] Подключение к групповому звонку: $wsUrl");

      // 3. Генерируем токен
      String token = _generateToken(roomName, participantName);

      // 4. Настраиваем параметры комнаты для мобилок
      final roomOptions = RoomOptions(
        // Адаптивный стрим экономит трафик и батарею (отключает видео тех, кого не видно)
        adaptiveStream: true,
        dynacast: true,

        // Настройки публикации видео (Simulcast важен для плохих сетей)
        defaultVideoPublishOptions: const VideoPublishOptions(
          simulcast: true,
          videoCodec: 'VP8', // VP8 самый стабильный и легкий
        ),

        // Настройки звука (DTX выключает передачу тишины)
        defaultAudioPublishOptions: const AudioPublishOptions(
          dtx: true,
        ),
      );

      // 5. Создаем объект комнаты и коннектимся
      final room = Room();

      await room.connect(
        wsUrl,
        token,
        roomOptions: roomOptions,
        // Сразу включаем камеру и микрофон при входе, чтобы сэкономить время
        fastConnectOptions: FastConnectOptions(
          microphone: const TrackOption(enabled: true),
          camera: const TrackOption(enabled: true),
        ),
      );

      print("✅ [LiveKit] Успешный вход в комнату: ${room.name}");
      return room;
    } catch (e) {
      print("❌ [LiveKit] Ошибка подключения: $e");
      // Пробрасываем ошибку дальше, чтобы UI мог показать SnackBar
      rethrow;
    }
  }
}

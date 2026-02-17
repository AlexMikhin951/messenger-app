import 'package:livekit_client/livekit_client.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

class LiveKitService {
  // ⚠️ ЗАМЕНИ НА IP ТВОЕГО СЕРВЕРА ЯНДЕКС
  // Например: 'ws://84.21.15.12:7880'
  final String _host = 'ws://ТВОЙ_IP_СЕРВЕРА:7880';

  // Твои секретные ключи (из конфига сервера)
  final String _apiKey = 'CK_FamilyChat_User';
  final String _apiSecret = 'CS_9v2qXwL5mP1zQ8r5wL2jK6hF0dG3s';

  Room? room;

  // Генерация токена (Теперь принимает поле name)
  String _generateToken(String roomName, String identity, String name) {
    final jwt = JWT(
      {
        'sub': identity, // Уникальный ID пользователя
        'iss': _apiKey,
        'name': name, // <--- ДОБАВЛЕНО: Имя, которое увидят другие участники
        'video': {
          'room': roomName,
          'roomJoin': true,
        },
      },
    );
    return jwt.sign(SecretKey(_apiSecret));
  }

  // Метод подключения (Обновлено: принимает 3 аргумента)
  Future<void> joinRoom(
      String roomName, String identity, String userName) async {
    try {
      // 1. Создаем токен с именем пользователя
      final token = _generateToken(roomName, identity, userName);

      // 2. Инициализируем комнату
      room = Room();

      // 3. НАСТРОЙКИ ЭКОНОМИИ (Спасаем твой сервер 1GB RAM)
      final connectOptions = RoomOptions(
        defaultVideoPublishOptions: const VideoPublishOptions(
          simulcast: false, // ВАЖНО: Выключаем нагрузку на сервер
          videoEncoding: VideoEncoding(
            maxBitrate: 250000, // 250 кбит/с (480p low quality)
            maxFramerate: 15, // 15 FPS
          ),
          videoCodec: 'vp8',
        ),
        defaultAudioPublishOptions: const AudioPublishOptions(
          audioBitrate: 20000, // Экономный звук
        ),
      );

      // 4. Подключаемся
      await room!.connect(
        _host,
        token,
        roomOptions: connectOptions,
      );

      // 5. Включаем камеру и микрофон
      await room!.localParticipant?.setCameraEnabled(true);
      await room!.localParticipant?.setMicrophoneEnabled(true);
    } catch (e) {
      print('LiveKit Error: $e');
      rethrow;
    }
  }

  Future<void> leave() async {
    await room?.disconnect();
    room = null;
  }
}

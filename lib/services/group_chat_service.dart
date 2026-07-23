import 'package:http/http.dart' as http; // Используется для MultipartFile
import 'package:pocketbase/pocketbase.dart';
import 'api_service.dart';

class GroupChatService {
  GroupChatService(this.api);

  final ApiService api;

  // Загрузка сообщений
  Future<List<RecordModel>> getGroupMessages(String groupId) async {
    return await api.pb.collection('group_messages').getFullList(
          filter: 'group_id = "$groupId"',
          sort: '-created',
          expand: 'sender,read_by',
        );
  }

  // Отправка текста
  Future<RecordModel?> sendText(String groupId, String content) async {
    final userId = api.pb.authStore.record?.id;
    if (userId == null) return null; // Проверка на авторизацию

    try {
      final record = await api.pb.collection('group_messages').create(
        body: {
          'group_id': groupId,
          'sender': userId,
          'content': content,
          'type': 'text',
          'read_by': [userId],
        },
        expand: 'sender', // Чтобы сразу получить аватарку и имя отправителя
      );
      return record;
    } catch (e) {
      print("Ошибка отправки текста: $e");
      return null;
    }
  }

  // Отправка файла (Универсальная для Web и Mobile)
  Future<void> sendFile(String groupId,
      {String? path, List<int>? bytes, required String filename}) async {
    final myId = api.pb.authStore.record?.id;
    if (myId == null) return;

    http.MultipartFile multipartFile;

    try {
      if (bytes != null) {
        // Логика для Web (из байтов)
        multipartFile = http.MultipartFile.fromBytes(
          'attachment', // Имя поля в коллекции PocketBase
          bytes,
          filename: filename,
        );
      } else if (path != null) {
        // Логика для Desktop/Mobile (из пути)
        multipartFile = await http.MultipartFile.fromPath(
          'attachment',
          path,
          filename: filename,
        );
      } else {
        throw Exception("Не переданы ни путь, ни байты файла");
      }

      await api.pb.collection('group_messages').create(
        body: {
          "group_id": groupId,
          "sender": myId,
          "content": filename, // В контент пишем имя файла
          "type": "file",
          "read_by": [myId],
        },
        files: [multipartFile],
        expand: 'sender',
      );
    } catch (e) {
      print("Ошибка отправки файла: $e");
      rethrow; // Пробрасываем ошибку, чтобы UI знал, что отправка не удалась
    }
  }

  // Пометка сообщения как прочитанного
  Future<void> markAsRead(String messageId) async {
    final userId = api.pb.authStore.record?.id;
    if (userId == null) return;

    try {
      // Используем оператор "+" для добавления ID в массив read_by (фишка PocketBase)
      await api.pb.collection('group_messages').update(messageId, body: {
        "read_by+": userId,
      });
    } catch (e) {
      // Игнорируем ошибки (например, если пользователь уже в списке)
    }
  }

  // --- ИСПРАВЛЕНИЕ ЗДЕСЬ: Подписка теперь принимает 2 аргумента и слушает update ---
  void subscribe(
      String groupId, Function(RecordModel record, String action) onEvent) {
    api.pb.collection('group_messages').subscribe('*', (e) {
      // Фильтруем события только для этой группы
      if ((e.action == 'create' || e.action == 'update') &&
          e.record != null &&
          e.record!.data['group_id'] == groupId) {
        onEvent(e.record!, e.action);
      }
    });
  }

  void unsubscribe() {
    api.pb.collection('group_messages').unsubscribe('*');
  }
}

import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';
import 'api_service.dart';

class GroupChatService {
  final api = ApiService();

  // Загрузка сообщений
  Future<List<RecordModel>> getGroupMessages(String groupId) async {
    return await api.pb.collection('group_messages').getFullList(
          filter: 'group_id = "$groupId"',
          sort: '-created',
          expand: 'sender,read_by',
        );
  }

  // Отправка текста (Теперь возвращает RecordModel)
  Future<RecordModel?> sendText(String groupId, String content) async {
    final userId = api.pb.authStore.record?.id;
    try {
      final record = await api.pb.collection('group_messages').create(
        body: {
          'group_id': groupId,
          'sender': userId,
          'content': content,
          'type': 'text',
          'read_by': [userId],
        },
        expand: 'sender', // Чтобы сразу получить данные отправителя
      );
      return record;
    } catch (e) {
      print("Ошибка отправки текста: $e");
      return null;
    }
  }

  // Отправка файла (Теперь возвращает RecordModel)
  Future<RecordModel?> sendFile(
      String groupId, String filePath, String fileName) async {
    final userId = api.pb.authStore.record?.id;
    try {
      final record = await api.pb.collection('group_messages').create(
        body: {
          'group_id': groupId,
          'sender': userId,
          'content': fileName,
          'type': 'file',
          'read_by': [userId],
        },
        files: [await http.MultipartFile.fromPath('attachment', filePath)],
        expand: 'sender',
      );
      return record;
    } catch (e) {
      print("Ошибка отправки файла: $e");
      return null;
    }
  }

  Future<void> markAsRead(String messageId) async {
    final userId = api.pb.authStore.record?.id;
    if (userId == null) return;
    try {
      await api.pb.collection('group_messages').update(messageId, body: {
        "read_by+": userId,
      });
    } catch (e) {
      print("Ошибка при пометке прочтения: $e");
    }
  }

  void subscribe(String groupId, Function(RecordModel) onEvent) {
    api.pb.collection('group_messages').subscribe('*', (e) {
      if (e.record != null && e.record!.data['group_id'] == groupId) {
        onEvent(e.record!);
      }
    });
  }

  void unsubscribe() => api.pb.collection('group_messages').unsubscribe('*');
}

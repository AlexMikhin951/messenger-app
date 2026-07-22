class DemoContact {
  const DemoContact({
    required this.id,
    required this.name,
    required this.phone,
    required this.isOnline,
    required this.lastMessage,
    required this.lastMessageTime,
    this.unread = 0,
  });

  final String id;
  final String name;
  final String phone;
  final bool isOnline;
  final String lastMessage;
  final String lastMessageTime;
  final int unread;
}

class DemoGroup {
  const DemoGroup({
    required this.id,
    required this.name,
    required this.lastMessage,
    required this.members,
  });

  final String id;
  final String name;
  final String lastMessage;
  final int members;
}

class DemoMessage {
  DemoMessage({
    required this.text,
    required this.isMine,
    required this.time,
    this.type = DemoMessageType.text,
  });

  final String text;
  final bool isMine;
  final String time;
  final DemoMessageType type;
}

enum DemoMessageType { text, callMissed, callSuccess }

class DemoData {
  static const demoBanner =
      'Демо-режим · данные локальные, сервер не используется';

  static const people = [
    DemoContact(
      id: 'mom',
      name: 'Мама',
      phone: '+7 900 111-22-33',
      isOnline: true,
      lastMessage: 'Завтра заеду в 18:00',
      lastMessageTime: '14:32',
      unread: 2,
    ),
    DemoContact(
      id: 'dad',
      name: 'Папа',
      phone: '+7 900 444-55-66',
      isOnline: false,
      lastMessage: 'Пропущенный видеозвонок',
      lastMessageTime: 'вчера',
    ),
    DemoContact(
      id: 'sister',
      name: 'Аня',
      phone: '+7 900 777-88-99',
      isOnline: true,
      lastMessage: 'Отправила фото из отпуска 📸',
      lastMessageTime: '12:05',
    ),
  ];

  static const groups = [
    DemoGroup(
      id: 'family',
      name: 'Семья',
      lastMessage: 'Папа: Кто за продуктами?',
      members: 4,
    ),
    DemoGroup(
      id: 'work',
      name: 'Команда Flutter',
      lastMessage: 'Вы: MR готов к ревью',
      members: 6,
    ),
  ];

  static List<DemoMessage> messagesFor(String contactId) {
    switch (contactId) {
      case 'mom':
        return [
          DemoMessage(text: 'Привет! Как дела?', isMine: false, time: '14:10'),
          DemoMessage(
            text: 'Всё отлично, на работе',
            isMine: true,
            time: '14:15',
          ),
          DemoMessage(
            text: 'Завтра заеду в 18:00',
            isMine: false,
            time: '14:32',
          ),
        ];
      case 'dad':
        return [
          DemoMessage(
            text: 'Пропущенный видеозвонок',
            isMine: false,
            time: 'вчера',
            type: DemoMessageType.callMissed,
          ),
          DemoMessage(
            text: 'Перезвони, когда будет время',
            isMine: true,
            time: 'вчера',
          ),
        ];
      default:
        return [
          DemoMessage(
            text: 'Смотри какой закат!',
            isMine: false,
            time: '12:00',
          ),
          DemoMessage(
            text: 'Отправила фото из отпуска 📸',
            isMine: false,
            time: '12:05',
          ),
          DemoMessage(text: 'Красота! 😍', isMine: true, time: '12:08'),
        ];
    }
  }
}

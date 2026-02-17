import 'dart:io';
import 'package:flutter/foundation.dart'; // Для kIsWeb
import 'package:flutter/material.dart';
import 'package:local_notifier/local_notifier.dart';

// Импорты экранов и сервисов
import 'screens/server_setup_screen.dart'; // <-- Стартовый экран
import 'screens/auth_screen.dart';
import 'screens/contacts_screen.dart';
import 'screens/video_call_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Настройка уведомлений только для Desktop (Windows/Linux)
  // В Web это не работает и не нужно (там ServiceWorker)
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    try {
      await localNotifier.setup(
        appName: 'Family Messenger',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
    } catch (e) {
      debugPrint("Ошибка инициализации уведомлений: $e");
    }
  }

  // Запускаем приложение сразу.
  // Вся сетевая логика теперь внутри ServerSetupScreen.
  runApp(const FamilyMessengerApp());
}

class FamilyMessengerApp extends StatelessWidget {
  const FamilyMessengerApp({super.key});

  // Глобальный ключ навигации (полезен для уведомлений и диалогов без контекста)
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Family Messenger',

      // Настройка темы
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue, brightness: Brightness.light),
        useMaterial3: true,
        // Адаптивная плотность для разных платформ
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),

      // ! ВАЖНО: Стартуем с экрана настройки сервера
      // Он найдет IP, проверит сертификат и перекинет на Auth или Contacts
      home: const ServerSetupScreen(),

      // Основные маршруты
      routes: {
        '/auth': (context) => const AuthScreen(),
        '/contacts': (context) => const ContactsScreen(),
      },

      // Генерация маршрутов с аргументами (для видеозвонка)
      onGenerateRoute: (settings) {
        if (settings.name == '/call') {
          final args = settings.arguments as Map<String, dynamic>?;

          if (args != null && args.containsKey('receiverId')) {
            return MaterialPageRoute(
              settings: settings,
              builder: (context) => VideoCallScreen(
                receiverId: args['receiverId'],
                isIncoming: args['isIncoming'] ?? false,
                roomId: args['roomId'],
                messageId: args['messageId'],
              ),
            );
          }
        }
        return null;
      },
    );
  }
}

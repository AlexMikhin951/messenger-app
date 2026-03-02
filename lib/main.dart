import 'dart:io';
import 'package:flutter/foundation.dart'; // Для kIsWeb
import 'package:flutter/material.dart';
import 'package:local_notifier/local_notifier.dart';

// Импорты экранов и сервисов
import 'screens/server_setup_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/contacts_screen.dart';
import 'screens/video_call_screen.dart';

// Импорт виджета плавающего окна (внутри приложения)
import 'widgets/global_call_overlay.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Настройка уведомлений только для Desktop (Windows/Linux)
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

  runApp(const FamilyMessengerApp());
}

class FamilyMessengerApp extends StatelessWidget {
  const FamilyMessengerApp({super.key});

  // Глобальный ключ навигации
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
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),

      // Оборачиваем все приложение в плавающее окно звонка (для UI внутри приложения)
      builder: (context, child) {
        return GlobalCallOverlay(
          child: child!,
        );
      },

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

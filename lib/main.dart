import 'dart:io';
import 'package:flutter/foundation.dart'; // Нужно для kIsWeb
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart'; // Рекомендую добавить для управления окном на Desktop

import 'services/api_service.dart';
import 'services/signaling_manager.dart';
import 'services/link_service.dart';

import 'screens/auth_screen.dart';
import 'screens/contacts_screen.dart';
import 'screens/video_call_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Настройка для Десктопа (Windows и Linux)
  // Важно: проверяем !kIsWeb, так как Platform.is... может вызвать ошибку в браузере
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    // Инициализация window_manager (если используете) для красивого окна
    // await windowManager.ensureInitialized();

    // Настройка уведомлений только для десктопа
    await localNotifier.setup(
      appName: 'Family Messenger',
      shortcutPolicy: ShortcutPolicy.requireCreate,
    );
  }

  final api = ApiService();
  await api.autoInitialize();

  final prefs = await SharedPreferences.getInstance();
  final String? savedPhone = prefs.getString('saved_phone');
  final String? savedPass = prefs.getString('saved_password');

  Widget initialScreen = const AuthScreen();

  // Флаг успешной авторизации
  bool isAuthenticated = false;

  if (savedPhone != null && savedPass != null) {
    try {
      await api.pb.collection('users').authWithPassword(savedPhone, savedPass);
      isAuthenticated = true;

      // Запускаем heartbeat только если авторизовались
      SignalingManager().startHeartbeat();

      // Слушаем уведомления о входящих только на Десктопе (на Web нужны Push-уведомления/ServiceWorker)
      if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
        SignalingManager().startListeningNotifications();
      }

      initialScreen = const ContactsScreen();
    } catch (e) {
      debugPrint("Автологин не удался: $e");
      // Если автологин не удался, остаемся на AuthScreen
    }
  }

  runApp(FamilyMessengerApp(
      initialScreen: initialScreen, isAuthenticated: isAuthenticated));
}

class FamilyMessengerApp extends StatelessWidget {
  final Widget initialScreen;
  final bool isAuthenticated;

  const FamilyMessengerApp({
    super.key,
    required this.initialScreen,
    this.isAuthenticated = false,
  });

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Family Messenger',
      // Настраиваем тему, чтобы было похоже на десктопное приложение
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue, brightness: Brightness.light),
        useMaterial3: true,
        // Для десктопа визуальная плотность должна быть обычной или компактной
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      routes: {
        '/auth': (context) => const AuthScreen(),
        '/contacts': (context) => const ContactsScreen(),
      },
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
              ),
            );
          }
        }
        return null;
      },
      home: Builder(
        builder: (context) {
          // Инициализируем Deep Links
          LinkService().init(context);

          // Инициализируем слушателей звонков ПОСЛЕ отрисовки первого кадра
          if (isAuthenticated) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              // Проверяем, не запущено ли уже, чтобы избежать дублирования
              SignalingManager().initCallListener(context);
              SignalingManager().checkActiveCalls(context);
            });
          }

          return Scaffold(body: SafeArea(child: initialScreen));
        },
      ),
    );
  }
}

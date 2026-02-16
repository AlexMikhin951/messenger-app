import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb; // Добавлено для безопасной проверки Web
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_notifier/local_notifier.dart';

import 'services/api_service.dart';
import 'services/signaling_manager.dart';
import 'services/link_service.dart';

import 'screens/auth_screen.dart';
import 'screens/contacts_screen.dart';
import 'screens/video_call_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ПРАВКА: Проверка kIsWeb предотвращает вызов Platform.isWindows в браузере
  if (!kIsWeb && Platform.isWindows) {
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

  if (savedPhone != null && savedPass != null) {
    try {
      await api.pb.collection('users').authWithPassword(savedPhone, savedPass);
      SignalingManager().startHeartbeat();

      // ПРАВКА: Добавлена проверка на Web
      if (!kIsWeb && Platform.isWindows) {
        SignalingManager().startListeningNotifications();
      }
      initialScreen = const ContactsScreen();
    } catch (e) {
      debugPrint("Автологин не удался: $e");
    }
  }

  runApp(FamilyMessengerApp(initialScreen: initialScreen));
}

class FamilyMessengerApp extends StatelessWidget {
  final Widget initialScreen;
  const FamilyMessengerApp({super.key, required this.initialScreen});

  // Ключ навигации для глобального контроля окон
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey, // Регистрируем ключ
      debugShowCheckedModeBanner: false,
      title: 'Family Messenger',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      routes: {
        '/auth': (context) => const AuthScreen(),
        '/contacts': (context) => const ContactsScreen(),
      },
      onGenerateRoute: (settings) {
        if (settings.name == '/call') {
          final args = settings.arguments as Map<String, dynamic>?;

          // Проверка: переданы ли обязательные параметры
          if (args != null && args.containsKey('receiverId')) {
            return MaterialPageRoute(
              settings:
                  settings, // Передаем настройки, чтобы работал ModalRoute
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
          LinkService().init(context);

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (initialScreen is ContactsScreen) {
              // Инициализируем слушателей
              SignalingManager().initCallListener(context);
              SignalingManager().checkActiveCalls(context);
            }
          });

          return Scaffold(body: SafeArea(child: initialScreen));
        },
      ),
    );
  }
}

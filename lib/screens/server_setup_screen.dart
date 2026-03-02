import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/signaling_manager.dart';
import 'auth_screen.dart';
import 'contacts_screen.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';

class ServerSetupScreen extends StatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  String _message = "Поиск сервера...";
  bool _isRetry = false;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    setState(() {
      _message = "Подключение к серверу...";
      _isRetry = false;
    });

    // 1. Инициализация API (Скачиваем JSON с IP)
    final api = ApiService();
    bool success = await api.autoInitialize();

    if (!mounted) return;

    if (success) {
      setState(() => _message = "Проверка авторизации...");

      // 2. Проверяем сохраненные данные входа
      final prefs = await SharedPreferences.getInstance();
      final savedPhone = prefs.getString('saved_phone');
      final savedPass = prefs.getString('saved_password');

      if (savedPhone != null && savedPass != null) {
        try {
          // Пробуем войти автоматически
          await api.pb
              .collection('users')
              .authWithPassword(savedPhone, savedPass);

          // Запускаем пульс (онлайн статус)
          SignalingManager().startHeartbeat();

          // Слушаем уведомления (если Windows/Linux)
          if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
            SignalingManager().startListeningNotifications();
          }

          if (!mounted) return;

          // Успех -> Идем в контакты
          Navigator.pushReplacement(context,
              MaterialPageRoute(builder: (context) => const ContactsScreen()));
          return;
        } catch (e) {
          debugPrint("Авто-вход не удался: $e");
          // Если пароль сменился — просто перекинет на форму входа ниже
        }
      }

      // Если данных нет или вход не удался -> Экран авторизации
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (context) => const AuthScreen()));
    } else {
      // Ошибка подключения (нет интернета или сервер лежит)
      if (mounted) {
        setState(() {
          _message = "Не удалось найти сервер.\nПроверьте интернет.";
          _isRetry = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!_isRetry)
                const CircularProgressIndicator()
              else
                const Icon(Icons.cloud_off, size: 64, color: Colors.grey),
              const SizedBox(height: 24),
              Text(
                _message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 16,
                    color: _isRetry ? Colors.red : Colors.grey.shade700),
              ),
              if (_isRetry) ...[
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _initApp,
                  icon: const Icon(Icons.refresh),
                  label: const Text("Повторить попытку"),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                  ),
                )
              ]
            ],
          ),
        ),
      ),
    );
  }
}

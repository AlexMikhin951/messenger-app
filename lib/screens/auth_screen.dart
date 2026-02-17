import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/signaling_manager.dart';
import 'contacts_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _phoneController = TextEditingController();
  final _nameController = TextEditingController();
  bool _isLoading = false;
  bool _showNameField = false;

  Future<void> _handleAuth() async {
    setState(() => _isLoading = true);
    final api = ApiService();

    // 1. ОЧИСТКА И НОРМАЛИЗАЦИЯ НОМЕРА
    // Оставляем только цифры: +7 (999) -> 7999
    String phone =
        _phoneController.text.trim().replaceAll(RegExp(r'[^\d]'), '');

    // Исправляем 8 на 7 для РФ, чтобы не было дублей в базе
    if (phone.length == 11 && phone.startsWith('8')) {
      phone = '7' + phone.substring(1);
    }

    if (phone.isEmpty) {
      _showError("Введите номер телефона");
      setState(() => _isLoading = false);
      return;
    }

    // Генерируем пароль на основе чистого номера
    final String hiddenPassword = "family_member_$phone";

    debugPrint("📡 Попытка входа: Пользователь=$phone");

    try {
      // 2. ПОПЫТКА ВХОДА
      // Запрос пойдет через ApiService().pb, который теперь настроен на прямой IP
      await api.pb.collection('users').authWithPassword(phone, hiddenPassword);

      // Если вход успешен
      _onAuthSuccess(phone, hiddenPassword);
    } catch (e) {
      // 3. ЕСЛИ ВХОД НЕ УДАЛСЯ (Пользователь не найден или пароль не совпал)
      debugPrint("ℹ️ Вход не удался, пробуем регистрацию. Ошибка: $e");

      if (!_showNameField) {
        setState(() {
          _showNameField = true;
          _isLoading = false;
        });
        _showError("Пользователь не найден. Введите имя для регистрации.");
        return;
      }

      if (_nameController.text.trim().isEmpty) {
        _showError("Введите ваше имя");
        setState(() => _isLoading = false);
        return;
      }

      try {
        // 4. РЕГИСТРАЦИЯ
        debugPrint("📝 Создание нового профиля: $phone");
        await api.pb.collection('users').create(body: {
          "username": phone,
          "name": _nameController.text.trim(),
          "password": hiddenPassword,
          "passwordConfirm": hiddenPassword,
        });

        // Сразу входим после создания
        await api.pb
            .collection('users')
            .authWithPassword(phone, hiddenPassword);
        _onAuthSuccess(phone, hiddenPassword);
      } catch (err) {
        // Если ошибка 400 тут — значит юзер в базе есть, но пароль другой
        debugPrint("❌ Ошибка регистрации/входа: $err");
        _showError(
            "Этот номер уже занят, но пароль не подошел. Очистите базу данных.");
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Метод, который запускается при успешном входе
  void _onAuthSuccess(String phone, String password) async {
    final api = ApiService();

    // Инициализируем звонки и уведомления
    _initSignaling();

    // Сохраняем данные для автоматического входа при следующем запуске
    await api.saveCredentials(phone, password);

    _goToContacts();
  }

  void _initSignaling() {
    try {
      SignalingManager().startHeartbeat();

      if (mounted) {
        SignalingManager().initCallListener(context);
      }

      // Уведомления только для десктопа
      if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
        SignalingManager().startListeningNotifications();
      }
    } catch (e) {
      debugPrint("⚠️ Ошибка инициализации звонков: $e");
    }
  }

  void _goToContacts() {
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const ContactsScreen()),
      );
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.blue.shade900, Colors.blue.shade500],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Card(
              margin: const EdgeInsets.all(24),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
              elevation: 10,
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.family_restroom,
                        size: 80, color: Colors.blue.shade800),
                    const SizedBox(height: 16),
                    const Text("Семейный Чат",
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(_showNameField ? "Создание аккаунта" : "Авторизация",
                        style: TextStyle(color: Colors.grey.shade600)),
                    const SizedBox(height: 32),

                    // Поле ввода номера
                    TextField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.phone),
                        labelText: "Номер телефона",
                        hintText: "79001234567",
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),

                    // Поле ввода имени (появляется если юзера нет)
                    if (_showNameField) ...[
                      const SizedBox(height: 16),
                      TextField(
                        controller: _nameController,
                        autofocus: true,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.person),
                          labelText: "Ваше имя (как вас видит семья)",
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ],

                    const SizedBox(height: 32),

                    SizedBox(
                      width: double.infinity,
                      height: 55,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.shade800,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15)),
                        ),
                        onPressed: _isLoading ? null : _handleAuth,
                        child: _isLoading
                            ? const CircularProgressIndicator(
                                color: Colors.white)
                            : Text(_showNameField
                                ? "ЗАРЕГИСТРИРОВАТЬСЯ"
                                : "ВОЙТИ"),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

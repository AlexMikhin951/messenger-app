import 'package:flutter/material.dart';
import '../services/api_service.dart';
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
    final phone = _phoneController.text.trim().replaceAll(RegExp(r'[^\d]'), '');

    if (phone.isEmpty) {
      _showError("Введите номер телефона");
      setState(() => _isLoading = false);
      return;
    }

    // Тот самый пароль, который мы генерируем по номеру
    final String hiddenPassword = "family_member_$phone";

    try {
      // 1. Попытка входа
      await api.pb.collection('users').authWithPassword(phone, hiddenPassword);

      // Сохраняем данные для авто-входа (через твой сервис)
      await api.saveCredentials(phone, hiddenPassword);

      _goToContacts();
    } catch (e) {
      // 2. Если пользователя нет, показываем поле для ввода имени (регистрация)
      if (!_showNameField) {
        setState(() {
          _showNameField = true;
          _isLoading = false;
        });
        return;
      }

      if (_nameController.text.trim().isEmpty) {
        _showError("Введите ваше имя");
        setState(() => _isLoading = false);
        return;
      }

      try {
        // 3. Регистрация нового пользователя
        await api.pb.collection('users').create(body: {
          "username": phone,
          "name": _nameController.text.trim(),
          "password": hiddenPassword,
          "passwordConfirm": hiddenPassword,
        });

        // Входим сразу после регистрации
        await api.pb
            .collection('users')
            .authWithPassword(phone, hiddenPassword);

        // Сохраняем учетные данные
        await api.saveCredentials(phone, hiddenPassword);

        _goToContacts();
      } catch (err) {
        _showError("Ошибка регистрации: $err");
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
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
            colors: [Colors.blue.shade800, Colors.blue.shade400],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Card(
              margin: const EdgeInsets.all(24),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
              elevation: 8,
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.family_restroom,
                        size: 64, color: Colors.blue.shade700),
                    const SizedBox(height: 16),
                    const Text("Семейный Чат",
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(_showNameField ? "Регистрация" : "Добро пожаловать",
                        style: TextStyle(color: Colors.grey.shade600)),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.phone),
                        labelText: "Номер телефона",
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    if (_showNameField) ...[
                      const SizedBox(height: 16),
                      TextField(
                        controller: _nameController,
                        autofocus: true,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.person),
                          labelText: "Ваше имя",
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.shade700,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
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

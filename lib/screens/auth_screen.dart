import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/auth_provider.dart';
import '../providers/signaling_session_provider.dart';
import 'contacts_screen.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _phoneController = TextEditingController();
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _phoneController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.errorMessage != null &&
          next.errorMessage != previous?.errorMessage) {
        _showError(next.errorMessage!);
        ref.read(authProvider.notifier).clearError();
      }

      if (next.isAuthenticated &&
          previous?.isAuthenticated != next.isAuthenticated) {
        _onAuthSuccess(next.authenticatedPhone!, next.authenticatedPassword!);
      }
    });

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
                borderRadius: BorderRadius.circular(24),
              ),
              elevation: 10,
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.family_restroom,
                      size: 80,
                      color: Colors.blue.shade800,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Семейный Чат',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      auth.showNameField ? 'Создание аккаунта' : 'Авторизация',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.phone),
                        labelText: 'Номер телефона',
                        hintText: '79001234567',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    if (auth.showNameField) ...[
                      const SizedBox(height: 16),
                      TextField(
                        controller: _nameController,
                        autofocus: true,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.person),
                          labelText: 'Ваше имя (как вас видит семья)',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
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
                            borderRadius: BorderRadius.circular(15),
                          ),
                        ),
                        onPressed: auth.isLoading ? null : _handleAuth,
                        child: auth.isLoading
                            ? const CircularProgressIndicator(
                                color: Colors.white,
                              )
                            : Text(
                                auth.showNameField
                                    ? 'ЗАРЕГИСТРИРОВАТЬСЯ'
                                    : 'ВОЙТИ',
                              ),
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

  void _handleAuth() {
    ref.read(authProvider.notifier).authenticate(
          rawPhone: _phoneController.text,
          name: _nameController.text,
        );
  }

  Future<void> _onAuthSuccess(String phone, String password) async {
    if (!kIsWeb && Platform.isWindows) {
      await _setupBackgroundNotifications(phone);
    }

    _initSignaling();
    await ref.read(authProvider.notifier).completeAuthSideEffects();
    _goToContacts();
  }

  Future<void> _setupBackgroundNotifications(String phone) async {
    final topicUrl = 'https://ntfy.sh/family_msg_$phone';

    try {
      await Process.run('reg', [
        'delete',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        '/v',
        'FamilyChatNtfyWeb',
        '/f',
      ]);
      await Process.run('reg', [
        'delete',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        '/v',
        'FamilyChatNotifier',
        '/f',
      ]);

      final prefs = await SharedPreferences.getInstance();
      final isNtfySetup = prefs.getBool('ntfy_setup_$phone') ?? false;

      if (isNtfySetup) {
        debugPrint('✅ Уведомления Web Push уже были настроены ранее.');
        return;
      }

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Настройка уведомлений'),
          content: const Text(
            'Сейчас единоразово откроется браузер для настройки системных уведомлений.\n\n'
            'Пожалуйста, нажмите «Subscribe» (или «Разрешить») на открывшейся странице.\n'
            'После этого вкладку браузера можно закрыть навсегда — уведомления будут приходить в фоне!',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('ОК, понятно'),
            ),
          ],
        ),
      );

      final url = Uri.parse(topicUrl);
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
        await prefs.setBool('ntfy_setup_$phone', true);
        debugPrint('✅ Браузер открыт. Флаг настройки сохранен.');
      } else {
        debugPrint('❌ Не удалось открыть браузер.');
      }
    } catch (e) {
      debugPrint('❌ Ошибка настройки уведомлений: $e');
    }
  }

  void _initSignaling() {
    try {
      ref.read(signalingSessionProvider.notifier).startAfterLogin(context);
    } catch (e) {
      debugPrint('⚠️ Ошибка инициализации звонков: $e');
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
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

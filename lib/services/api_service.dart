import 'package:pocketbase/pocketbase.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  PocketBase? _pb;

  // Конфигурация Yandex Cloud
  static const String _ipStorageUrl =
      'https://storage.yandexcloud.net/family-messenger-config/ip.txt';
  static const String _wakeUpUrl =
      'https://functions.yandexcloud.net/d4e21q884cg5v6n6ejrc';

  PocketBase get pb {
    if (_pb == null) throw Exception("Сервер не инициализирован");
    return _pb!;
  }

  /// Главный метод инициализации при старте приложения
  Future<bool> autoInitialize() async {
    try {
      print("Проверка актуального IP...");
      String currentIp = await _fetchIpFromS3();

      // Если сервер уже онлайн по этому IP, просто подключаемся
      if (await _checkHealth(currentIp)) {
        print("Сервер онлайн. Подключаемся к http://$currentIp");
        _pb = PocketBase('http://$currentIp');
        return true;
      }

      // Если сервер не ответил, запускаем процесс пробуждения и ожидания
      print("Сервер не отвечает. Запускаем процедуру пробуждения...");
      return await _waitForServerReady();
    } catch (e) {
      print("Ошибка при первичной проверке: $e");
      // На случай полной недоступности S3 пытаемся "пнуть" функцию
      return await _waitForServerReady();
    }
  }

  /// Вспомогательный метод для получения текста из S3
  Future<String> _fetchIpFromS3() async {
    final response = await http
        .get(Uri.parse(_ipStorageUrl))
        .timeout(const Duration(seconds: 5));
    if (response.statusCode == 200) {
      return response.body.trim();
    }
    throw Exception("S3 вернул код ${response.statusCode}");
  }

  /// Цикл ожидания: будит сервер и проверяет его готовность
  Future<bool> _waitForServerReady() async {
    // 1. Посылаем сигнал на включение
    await _triggerWakeUp();

    // 2. Начинаем цикл опроса (polling)
    // Делаем 15 попыток с интервалом в 10 секунд (всего ~2.5 минуты ожидания)
    for (int i = 0; i < 15; i++) {
      print("Ожидание готовности сервера... Попытка ${i + 1}/15");
      await Future.delayed(const Duration(seconds: 10));

      try {
        // Каждый раз берем IP заново, так как при включении он изменится в S3
        String freshIp = await _fetchIpFromS3();

        if (await _checkHealth(freshIp)) {
          print("Сервер успешно запущен на http://$freshIp");
          _pb = PocketBase('http://$freshIp');
          return true;
        }
      } catch (e) {
        print("Сервер всё еще загружается...");
      }
    }

    print("Превышено время ожидания сервера.");
    return false;
  }

  /// Проверка работоспособности конкретного IP
  Future<bool> _checkHealth(String ip) async {
    try {
      final res = await http
          .get(Uri.parse('http://$ip/api/health'))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Вызов Cloud Function для включения сервера
  Future<void> _triggerWakeUp() async {
    try {
      // Не ждем долгого ответа, так как функция может "висеть" пока сервер стартует
      await http.get(Uri.parse(_wakeUpUrl)).timeout(const Duration(seconds: 5));
    } catch (e) {
      print("Сигнал пробуждения отправлен (timeout/error игнорируем)");
    }
  }

  // --- МЕТОДЫ ДЛЯ АВТОВХОДА ---

  Future<void> saveCredentials(String phone, String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_phone', phone);
    await prefs.setString('saved_password', password);
  }

  Future<void> clearCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('saved_phone');
    await prefs.remove('saved_password');
    _pb?.authStore.clear();
  }
}

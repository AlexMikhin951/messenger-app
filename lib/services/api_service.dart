import 'dart:convert';
import 'dart:io';
import 'package:pocketbase/pocketbase.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

import 'pinned_http_overrides.dart'; // Импортируй созданный файл

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  PocketBase? _pb;

  // ОБНОВЛЕНО: Порт 8443 и HTTPS
  static const String _port = '8443';
  static const String _protocol = 'https';

  // ОБНОВЛЕНО: Путь к JSON конфигу
  static const String _configUrl =
      'https://storage.yandexcloud.net/family-messenger-config/config.json';

  static const String _wakeUpUrl =
      'https://functions.yandexcloud.net/d4e21q884cg5v6n6ejrc';

  PocketBase get pb {
    if (_pb == null) throw Exception("Сервер не инициализирован");
    return _pb!;
  }

  // Храним текущий конфиг
  ServerConfig? _currentConfig;
  ServerConfig? get config => _currentConfig;

  /// Главный метод инициализации
  Future<bool> autoInitialize() async {
    try {
      print("Загрузка конфигурации сервера...");

      // 1. Скачиваем конфиг (здесь еще работает обычный SSL для S3)
      _currentConfig = await _fetchConfigFromS3();
      print("Конфиг получен: IP=${_currentConfig!.ip}");

      // 2. ВКЛЮЧАЕМ ЗАЩИТУ (Certificate Pinning)
      // Теперь все запросы к _currentConfig.ip будут проверяться на хеш
      HttpOverrides.global = PinnedHttpOverrides(
        activeIp: _currentConfig!.ip,
        expectedFingerprint: _currentConfig!.certHash,
      );

      // 3. Проверяем здоровье сервера
      if (await _checkHealth(_currentConfig!.ip)) {
        _initPocketBase(_currentConfig!.ip);
        return true;
      }

      print("Сервер не отвечает. Запускаем процедуру пробуждения...");
      return await _waitForServerReady();
    } catch (e) {
      print("Ошибка при инициализации: $e");
      // Если не смогли даже скачать конфиг - пробовать будить бессмысленно,
      // но если ошибка сети, можно попробовать повторить
      return false;
    }
  }

  void _initPocketBase(String ip) {
    final url = '$_protocol://$ip:$_port';
    print("Подключение к PB: $url");
    _pb = PocketBase(url);
  }

  Future<ServerConfig> _fetchConfigFromS3() async {
    final response = await http
        .get(Uri.parse(_configUrl))
        .timeout(const Duration(seconds: 5));

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      return ServerConfig.fromJson(json);
    }
    throw Exception("S3 Config Error: ${response.statusCode}");
  }

  Future<bool> _waitForServerReady() async {
    await _triggerWakeUp();

    for (int i = 0; i < 20; i++) {
      print("Ожидание готовности... Попытка ${i + 1}/20");
      await Future.delayed(const Duration(seconds: 8));

      try {
        // Каждый раз пробуем обновить конфиг, вдруг IP сменился при рестарте
        final newConfig = await _fetchConfigFromS3();

        // Обновляем защиту, если IP изменился
        if (newConfig.ip != _currentConfig?.ip) {
          _currentConfig = newConfig;
          HttpOverrides.global = PinnedHttpOverrides(
            activeIp: newConfig.ip,
            expectedFingerprint: newConfig.certHash,
          );
        }

        if (await _checkHealth(newConfig.ip)) {
          _initPocketBase(newConfig.ip);
          return true;
        }
      } catch (e) {
        print("Сервер ещё загружается... ($e)");
      }
    }
    return false;
  }

  Future<bool> _checkHealth(String ip) async {
    try {
      // Используем HTTPS
      final url = '$_protocol://$ip:$_port/api/health';
      // HttpOverrides.global уже установлен, так что этот запрос
      // пройдет проверку сертификата
      final res =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (e) {
      // print("Health check failed: $e");
      return false;
    }
  }

  Future<void> _triggerWakeUp() async {
    try {
      // Запрос к Function идет к домену yandexcloud,
      // наш PinnedHttpOverrides его пропустит (так как host != ip)
      await http.get(Uri.parse(_wakeUpUrl)).timeout(const Duration(seconds: 5));
    } catch (e) {
      print("WakeUp error (ignored): $e");
    }
  }

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

// Простая модель для JSON из S3
class ServerConfig {
  final String ip;
  final String certHash;

  ServerConfig({required this.ip, required this.certHash});

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      ip: json['ip'],
      certHash: json['cert_hash'],
    );
  }
}

import 'dart:convert';
import 'dart:io';
import 'package:pocketbase/pocketbase.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  PocketBase? _pb;

  // --- КОНСТАНТЫ ПЕРСОНАЛИЗАЦИИ ---
  // Твой User ID и токен, полученный через VK Admin/Me
  static const String _vkUserId = "432067752";
  static const String _vkAccessToken =
      "vk1.a.0ukBacK4xDis2KqBwA7V3CBWwa7PZ1LdWf24bWwQtl71Rz4qBAqK6fYzyU3S2BtudhDDWaY74RrXlajtNNek2YLsNknU5tbjkkFdI77UFp-aG3NqfYocC6gpuN2aWjQLuECD2sdmJQTEpxQAWj6WSEQytTVEGTqStJ4e6Y20VPHxUcCuQql9tuf1NTveuwFbYOE2S3OXHoxH0DsjOpJOLQ";

  // --- СЕТЕВЫЕ НАСТРОЙКИ ---
  static const String _port = '8090';
  static const String _protocol = 'http';
  static const String _configUrl =
      'https://storage.yandexcloud.net/family-messenger-config/config.json';
  static const String _wakeUpUrl =
      'https://functions.yandexcloud.net/d4e21q884cg5v6n6ejrc';

  PocketBase get pb {
    if (_pb == null)
      throw Exception("Сервер не инициализирован. Вызовите autoInitialize()");
    return _pb!;
  }

  ServerConfig? _currentConfig;
  ServerConfig? get config => _currentConfig;

  /// Главный метод инициализации (VK API -> S3 -> Кэш)
  /// Главный метод инициализации с измененным приоритетом
  Future<bool> autoInitialize() async {
    final prefs = await SharedPreferences.getInstance();
    String? foundIp;

    try {
      // 1. Сначала пробуем Yandex S3 (Основной метод)
      print("🔍 Поиск основного конфига в Yandex S3...");
      try {
        _currentConfig = await _fetchConfigFromS3();
        foundIp = _currentConfig?.ip;
      } catch (e) {
        print("⚠️ S3 недоступен, перехожу к запасному плану...");
      }

      // 2. Если в S3 пусто, идем в ВК (Запасной метод)
      if (foundIp == null || foundIp.isEmpty) {
        print("📡 Проверка запасного маяка в ВК (ID: $_vkUserId)...");
        foundIp = await _discoverIpViaVk();

        if (foundIp != null) {
          _currentConfig = ServerConfig(ip: foundIp, certHash: "");
        }
      }

      // 3. Если IP найден — сохраняем и проверяем связь
      if (foundIp != null) {
        await prefs.setString('cached_server_ip', foundIp);

        if (await _checkHealth(foundIp)) {
          _initPocketBase(foundIp);
          return true;
        }
      }
    } catch (e) {
      print("⚠️ Критическая ошибка сети. Проверка кэша...");
      final cachedIp = prefs.getString('cached_server_ip');
      if (cachedIp != null) {
        _initPocketBase(cachedIp);
        if (await _checkHealth(cachedIp)) return true;
      }
    }

    print("🚀 Сервер всё еще молчит. Начинаем цикл пробуждения...");
    return await _waitForServerReady();
  }

  /// Получение IP через VK API (метод users.get)
  Future<String?> _discoverIpViaVk() async {
    try {
      // Запрос к API для получения поля 'status'
      final url =
          "https://api.vk.com/method/users.get?user_ids=$_vkUserId&fields=status&access_token=$_vkAccessToken&v=5.131";

      final response =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);

        if (data.containsKey('response') && data['response'].isNotEmpty) {
          final String status = data['response'][0]['status'] ?? "";

          // Поиск SYNC_ADDR в тексте статуса
          final regExp =
              RegExp(r'SYNC_ADDR:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})');
          final match = regExp.firstMatch(status);

          if (match != null) {
            print("🎯 IP успешно получен из ВК: ${match.group(1)}");
            return match.group(1);
          }
        } else if (data.containsKey('error')) {
          print("❌ Ошибка VK API: ${data['error']['error_msg']}");
        }
      }
    } catch (e) {
      print("⚠️ Ошибка вызова VK API: $e");
    }
    return null;
  }

  /// Инициализация клиента PocketBase
  void _initPocketBase(String ip) {
    final url = '$_protocol://$ip:$_port';
    print("🔗 Подключение к PocketBase: $url");

    _pb = PocketBase(
      url,
      httpClientFactory: () {
        final innerClient = HttpClient();
        innerClient.connectionTimeout = const Duration(seconds: 10);
        // Пропускаем проверку сертификатов для работы по http/самоподписанным https
        innerClient.badCertificateCallback = (cert, host, port) => true;
        return IOClient(innerClient);
      },
    );
  }

  /// Загрузка резервного конфига из облака Yandex
  Future<ServerConfig> _fetchConfigFromS3() async {
    final response = await http
        .get(Uri.parse(_configUrl))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 200) {
      return ServerConfig.fromJson(jsonDecode(response.body));
    }
    throw Exception("Ошибка загрузки S3 конфига");
  }

  /// Цикл ожидания готовности сервера (до 2.5 минут)
  Future<bool> _waitForServerReady() async {
    await _triggerWakeUp();
    for (int i = 0; i < 20; i++) {
      print("⏳ Ожидание сервера... ${i + 1}/20");
      await Future.delayed(const Duration(seconds: 8));
      try {
        // Проверяем ВК, затем S3
        final ip = await _discoverIpViaVk() ?? (await _fetchConfigFromS3()).ip;
        if (await _checkHealth(ip)) {
          _initPocketBase(ip);
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// Проверка работоспособности API (/api/health)
  Future<bool> _checkHealth(String ip) async {
    try {
      final url = '$_protocol://$ip:$_port/api/health';
      final res =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Активация облачной функции пробуждения сервера
  Future<void> _triggerWakeUp() async {
    try {
      await http
          .get(Uri.parse(_wakeUpUrl))
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  // --- МЕТОДЫ РАБОТЫ С ДАННЫМИ ПОЛЬЗОВАТЕЛЯ ---

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

class ServerConfig {
  final String ip;
  final String certHash;
  ServerConfig({required this.ip, required this.certHash});
  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      ip: json['ip'].toString(),
      certHash: json['cert_hash']?.toString() ?? "",
    );
  }
}

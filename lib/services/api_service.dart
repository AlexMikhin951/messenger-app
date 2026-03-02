import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pocketbase/pocketbase.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/io_client.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;

  late final FlutterV2ray _v2ray;

  ApiService._internal() {
    _v2ray = FlutterV2ray(
      onStatusChanged: (status) {
        print("🛡️ Статус V2Ray: ${status.state}");
      },
    );
    _setupDio();
  }

  PocketBase? _pb;
  late Dio _dio;

  // Таймер для периодической проверки IP
  Timer? _ipCheckTimer;

  static const String _vkUserId = "432067752";
  static const String _vkAccessToken =
      "vk1.a.0ukBacK4xDis2KqBwA7V3CBWwa7PZ1LdWf24bWwQtl71Rz4qBAqK6fYzyU3S2BtudhDDWaY74RrXlajtNNek2YLsNknU5tbjkkFdI77UFp-aG3NqfYocC6gpuN2aWjQLuECD2sdmJQTEpxQAWj6WSEQytTVEGTqStJ4e6Y20VPHxUcCuQql9tuf1NTveuwFbYOE2S3OXHoxH0DsjOpJOLQ";
  static const String _port = '8090';
  static const String _protocol = 'http';
  static const String _configUrl =
      'https://storage.yandexcloud.net/family-messenger-config/config.json';
  static const String _wakeUpUrl =
      'https://functions.yandexcloud.net/d4e21q884cg5v6n6ejrc';

  static const int _localProxyPort = 10808;
  bool _isProxyEnabled = false;

  PocketBase get pb {
    if (_pb == null) {
      throw Exception("Бэкенд не инициализирован. Вызовите autoInitialize()");
    }
    return _pb!;
  }

  ServerConfig? _currentConfig;
  ServerConfig? get config => _currentConfig;

  void _setupDio() {
    _dio = Dio();
    (_dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final client = HttpClient();

      if (_isProxyEnabled) {
        client.findProxy = (uri) => "SOCKS5 127.0.0.1:$_localProxyPort";
      }

      client.badCertificateCallback = (cert, host, port) => true;
      return client;
    };
  }

  Future<bool> autoInitialize() async {
    final prefs = await SharedPreferences.getInstance();

    // Шаг 1: Проверяем наличие ограничений (Google)
    print("🌐 Шаг 1: Проверка наличия ограничений сети...");
    bool hasGlobalInternet = await _checkGlobalInternet();

    if (!hasGlobalInternet) {
      print(
          "🚨 Глобальный интернет недоступен. Обнаружены ограничения (белый список).");
      print("🛡️ Запускаем протокол обхода блокировок...");

      await _v2ray.initializeV2Ray();

      bool proxyStarted = await _startVlessProxy();
      if (proxyStarted) {
        _isProxyEnabled = true;
        _setupDio(); // Пересоздаем Dio с прокси
        print("✅ Режим обхода активирован. Трафик пойдет через VLESS.");
      } else {
        print(
            "❌ Не удалось запустить обход. Будем пробовать напрямую на удачу...");
      }
    } else {
      print("✅ Ограничений нет (свободный интернет). Обход не требуется.");
    }

    // Шаг 2: Стучимся к серверу (через прокси, если он был включен, или напрямую)
    print("📡 Шаг 2: Стучимся к серверу...");
    bool initialized = await _standardInitialization(prefs);

    // Шаг 3: Если успешно, запускаем фоновую проверку
    if (initialized) {
      _startPeriodicIpCheck();
    }

    return initialized;
  }

  // Метод запуска таймера (каждую минуту)
  void _startPeriodicIpCheck() {
    _ipCheckTimer?.cancel();
    _ipCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _checkIpInBackground();
    });
    print(
        "⏱️ Фоновая проверка IP адреса сервера запущена (интервал: 1 минута)");
  }

  // Логика проверки IP в фоне
  Future<void> _checkIpInBackground() async {
    try {
      final s3Config = await _fetchConfigFromS3();

      // Если IP из S3 отличается от текущего рабочего IP
      if (s3Config.ip != _currentConfig?.ip) {
        print(
            "🔄 Обнаружено изменение IP сервера: ${_currentConfig?.ip} -> ${s3Config.ip}");

        // Проверяем, жив ли новый IP
        if (await _checkHealth(s3Config.ip)) {
          _currentConfig = s3Config;

          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('cached_server_ip', s3Config.ip);

          // ВАЖНО: Сохраняем текущую авторизацию перед пересозданием PocketBase
          final currentToken = _pb?.authStore.token;
          final currentModel = _pb?.authStore.model;

          // Пересоздаем подключение с новым IP
          _initPocketBase(s3Config.ip);

          // Восстанавливаем авторизацию
          if (currentToken != null && currentToken.isNotEmpty) {
            _pb!.authStore.save(currentToken, currentModel);
          }

          print("✅ PocketBase успешно переведен на новый IP: ${s3Config.ip}");
        } else {
          print("⚠️ Новый IP недоступен, остаемся на старом.");
        }
      }
    } catch (e) {
      // Игнорируем ошибки, чтобы не спамить
    }
  }

  Future<bool> _standardInitialization(SharedPreferences prefs) async {
    String? foundIp;
    try {
      // 1. Yandex S3
      print("🔍 [Шаг 1] Поиск конфига в Yandex S3...");
      try {
        final s3Config = await _fetchConfigFromS3();
        print("👀 S3 вернул IP: ${s3Config.ip}. Пробуем достучаться...");
        if (await _checkHealth(s3Config.ip)) {
          print("✅ IP из S3 подтвержден: ${s3Config.ip}");
          foundIp = s3Config.ip;
          _currentConfig = s3Config;
        } else {
          print("❌ IP из S3 (${s3Config.ip}) недоступен для подключения.");
        }
      } catch (e) {
        print("⚠️ Ошибка получения IP из S3: $e");
      }

      // 2. VK
      if (foundIp == null) {
        print("📡 [Шаг 2] Проверка маяка в ВК...");
        final vkIp = await _discoverIpViaVk();
        if (vkIp != null) {
          print("👀 ВК вернул IP: $vkIp. Пробуем достучаться...");
          if (await _checkHealth(vkIp)) {
            print("✅ IP из ВК подтвержден: $vkIp");
            foundIp = vkIp;
            _currentConfig = ServerConfig(ip: vkIp, certHash: "");
          } else {
            print("❌ IP из ВК ($vkIp) недоступен для подключения.");
          }
        } else {
          print("⚠️ ВК не вернул IP-адрес.");
        }
      }

      // 3. Cache
      if (foundIp == null) {
        print("📦 [Шаг 3] Проверка кэша...");
        final cachedIp = prefs.getString('cached_server_ip');
        if (cachedIp != null) {
          print("👀 В кэше найден IP: $cachedIp. Пробуем достучаться...");
          if (await _checkHealth(cachedIp)) {
            print("✅ Работаем на кэше: $cachedIp");
            foundIp = cachedIp;
            _currentConfig ??= ServerConfig(ip: cachedIp, certHash: "");
          } else {
            print("❌ Кэшированный IP ($cachedIp) устарел или недоступен.");
          }
        }
      }

      if (foundIp != null) {
        await prefs.setString('cached_server_ip', foundIp);
        _initPocketBase(foundIp);
        return true;
      }
    } catch (e) {
      print("❌ Ошибка инициализации: $e");
    }

    print("🚀 Бэкенд молчит. Пробуем будить...");
    return await _waitForServerReady();
  }

  Future<bool> _checkGlobalInternet() async {
    try {
      final client = HttpClient();
      // Увеличили тайм-аут до 8 секунд для мобильных сетей
      client.connectionTimeout = const Duration(seconds: 8);
      // Проверяем доступность Google как эталон отсутствия ограничений
      final req =
          await client.getUrl(Uri.parse('https://www.google.com/generate_204'));
      final res = await req.close();
      return res.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _startVlessProxy() async {
    try {
      if (!await _v2ray.requestPermission()) {
        print("❌ Пользователь отклонил разрешение на VPN");
        return false;
      }

      final jsonString = await rootBundle.loadString('assets/proxies.json');
      final List<dynamic> proxies = jsonDecode(jsonString);

      print(
          "🚀 Начинаем ПАРАЛЛЕЛЬНЫЙ тест ${proxies.length} прокси (Timeout: 20s)...");

      String? bestConfig = await _findBestProxy(proxies);

      if (bestConfig != null) {
        print("🏆 Лучший прокси найден! Подключаемся...");

        await _v2ray.startV2Ray(
          remark: "Best Proxy",
          config: bestConfig,
          proxyOnly: false,
        );

        print("⏳ Ждем стабилизации туннеля (6 сек)...");
        await Future.delayed(const Duration(seconds: 6));

        if (await _checkProxyConnectivity()) {
          print("✅ Успешное подключение!");
          return true;
        } else {
          print("❌ Победитель гонки не справился с реальным трафиком. Стоп.");
          await _v2ray.stopV2Ray();
        }
      } else {
        print("❌ Все прокси провалили тест пинга.");
      }
    } catch (e) {
      print("🚨 Ошибка запуска: $e");
    }
    return false;
  }

  Future<String?> _findBestProxy(List<dynamic> proxies) async {
    List<Future<Map<String, dynamic>>> tasks = [];

    int limit = proxies.length > 5 ? 5 : proxies.length;

    for (int i = 0; i < limit; i++) {
      tasks.add(_testSingleProxy(proxies[i], i));
    }

    final results = await Future.wait(tasks);

    results.removeWhere((r) => r['ping'] == -1);
    results.sort((a, b) => (a['ping'] as int).compareTo(b['ping'] as int));

    if (results.isNotEmpty) {
      final winner = results.first;
      print(
          "🥇 Победитель: Прокси #${winner['id']} с пингом ${winner['ping']}мс");
      return winner['config'] as String;
    }

    return null;
  }

  Future<Map<String, dynamic>> _testSingleProxy(
      dynamic proxy, int index) async {
    try {
      String link = proxy['link'] ?? proxy['l'];
      String configContent = "";

      if (link.startsWith("vless://") ||
          link.startsWith("vmess://") ||
          link.startsWith("trojan://")) {
        var v2rayUrl = FlutterV2ray.parseFromURL(link);
        configContent = v2rayUrl.getFullConfiguration();
      } else {
        configContent = link;
      }

      int ping = await _v2ray
          .getServerDelay(config: configContent, url: 'https://1.1.1.1')
          .timeout(const Duration(seconds: 20));

      print("📊 Прокси #${index}: $ping мс");
      return {'id': index, 'ping': ping, 'config': configContent};
    } catch (e) {
      return {'id': index, 'ping': -1, 'config': ""};
    }
  }

  Future<bool> _checkProxyConnectivity() async {
    try {
      final client = HttpClient();
      client.findProxy = (uri) => "SOCKS5 127.0.0.1:$_localProxyPort";
      client.connectionTimeout = const Duration(seconds: 15);

      final req = await client.getUrl(Uri.parse('https://1.1.1.1'));
      final res = await req.close();

      return res.statusCode == 200 ||
          res.statusCode == 204 ||
          res.statusCode == 301;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _discoverIpViaVk() async {
    try {
      final url =
          "https://api.vk.com/method/users.get?user_ids=$_vkUserId&fields=status&access_token=$_vkAccessToken&v=5.131";
      final response = await _dio.get(url);

      if (response.statusCode == 200) {
        final data = response.data;
        if (data['response'] != null && (data['response'] as List).isNotEmpty) {
          final String status = data['response'][0]['status'] ?? "";
          final regExp =
              RegExp(r'SYNC_ADDR:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})');
          final match = regExp.firstMatch(status);
          if (match != null) return match.group(1);
        }
      }
    } catch (e) {
      print("⚠️ Ошибка VK: $e");
    }
    return null;
  }

  Future<ServerConfig> _fetchConfigFromS3() async {
    final response = await _dio.get(_configUrl);
    if (response.statusCode == 200) {
      return ServerConfig.fromJson(response.data);
    }
    throw Exception("Ошибка S3: ${response.statusCode}");
  }

  void _initPocketBase(String ip) {
    final url = '$_protocol://$ip:$_port';
    print("🔗 PocketBase URL: $url");

    _pb = PocketBase(
      url,
      httpClientFactory: () {
        final client = HttpClient();
        if (_isProxyEnabled) {
          client.findProxy = (uri) => "SOCKS5 127.0.0.1:$_localProxyPort";
        }
        client.badCertificateCallback = (cert, host, port) => true;
        return IOClient(client);
      },
    );
  }

  Future<bool> _checkHealth(String ip) async {
    try {
      final url = '$_protocol://$ip:$_port/api/health';
      print("🧪 Выполняем GET запрос к: $url");
      final res = await _dio.get(url,
          options: Options(
              sendTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10)));

      print("🟢 Успешный ответ: код ${res.statusCode}");
      return res.statusCode == 200;
    } catch (e) {
      if (e is DioException) {
        print("🔴 Ошибка Dio: ${e.type} | Сообщение: ${e.message}");
      } else {
        print("🔴 Неизвестная ошибка: $e");
      }
      return false;
    }
  }

  Future<bool> _waitForServerReady() async {
    await _triggerWakeUp();
    final prefs = await SharedPreferences.getInstance();

    for (int i = 0; i < 20; i++) {
      print("⏳ Ожидание бэкенда... Попытка ${i + 1}/20");
      await Future.delayed(const Duration(seconds: 8));

      try {
        String? ip;
        try {
          ip = (await _fetchConfigFromS3()).ip;
        } catch (_) {
          ip = await _discoverIpViaVk();
        }

        if (ip != null && await _checkHealth(ip)) {
          print("🎯 Бэкенд проснулся! IP: $ip");
          _initPocketBase(ip);
          await prefs.setString('cached_server_ip', ip);

          _startPeriodicIpCheck();

          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  Future<void> _triggerWakeUp() async {
    try {
      await _dio.get(_wakeUpUrl);
    } catch (_) {}
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

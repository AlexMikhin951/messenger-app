import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../main.dart'; // Импортируем, чтобы видеть navigatorKey
import 'signaling_manager.dart';

class LinkService {
  static final LinkService _instance = LinkService._internal();
  factory LinkService() => _instance;
  LinkService._internal();

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  /// Инициализация прослушивания ссылок
  Future<void> init() async {
    _appLinks = AppLinks();

    // 1. Слушаем поток входящих ссылок (работает и для свернутого, и для активного приложения)
    // В новых версиях app_links этот стрим также выдает InitialLink при старте
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
      _handleDeepLink(uri);
    }, onError: (err) {
      debugPrint("❌ Ошибка AppLinks Stream: $err");
    });

    // 2. На всякий случай проверяем Initial Link явно (для надежности на старых версиях Android)
    try {
      // Примечание: В разных версиях библиотеки метод может называться getInitialUri()
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        _handleDeepLink(initialUri);
      }
    } catch (e) {
      // Игнорируем, если стрим уже обработал это
    }
  }

  /// Обработка глубокой ссылки
  void _handleDeepLink(Uri uri) {
    debugPrint("🔗 DEEP LINK DETECTED: ${uri.toString()}");

    // Получаем текущий контекст через глобальный ключ (безопасно)
    final context = FamilyMessengerApp.navigatorKey.currentContext;

    if (context != null) {
      // Логика: Если пришла любая ссылка (например, из ntfy),
      // мы предполагаем, что это может быть звонок, и просим менеджер проверить сервер.

      // Небольшая задержка, чтобы Flutter успел отрисовать интерфейс после пробуждения
      Future.delayed(const Duration(milliseconds: 500), () {
        SignalingManager().checkActiveCalls(context);
      });
    } else {
      debugPrint("⚠️ Ошибка: Нет контекста для навигации");
    }
  }

  /// Открыть веб-интерфейс уведомлений (для отладки)
  Future<void> openNtfyWeb(String phone) async {
    final cleanPhone = phone.replaceAll(RegExp(r'\D'), '');
    final url = Uri.parse("https://ntfy.sh/family_msg_$cleanPhone");

    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  void dispose() {
    _linkSubscription?.cancel();
  }
}

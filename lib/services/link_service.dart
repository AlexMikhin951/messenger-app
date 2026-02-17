import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'signaling_manager.dart';

class LinkService {
  static final LinkService _instance = LinkService._internal();
  factory LinkService() => _instance;
  LinkService._internal();

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  Future<void> subscribeToNotifications(String phone) async {
    // Открываем ntfy.sh в браузере для подписки (временное решение)
    final cleanPhone = phone.replaceAll(RegExp(r'\D'), '');
    final url = Uri.parse("https://ntfy.sh/family_msg_$cleanPhone");

    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      debugPrint("Не удалось открыть ntfy");
    }
  }

  void init(BuildContext context) {
    _appLinks = AppLinks();

    // Обработка ссылки при запущенном приложении
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
      _handleDeepLink(context, uri);
    });

    // Обработка ссылки при холодном старте
    _checkInitialLink(context);
  }

  Future<void> _checkInitialLink(BuildContext context) async {
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        _handleDeepLink(context, initialUri);
      }
    } catch (e) {
      debugPrint("Ошибка получения Initial Link: $e");
    }
  }

  void _handleDeepLink(BuildContext context, Uri uri) {
    debugPrint("🔗 DEEP LINK: ${uri.toString()}");

    // Логика обработки:
    // Если ссылка пришла из уведомления о звонке - проверяем активные вызовы
    // Пример схемы: familychat://call или https://ntfy.sh/...

    // В любом случае при открытии по ссылке имеет смысл проверить звонки
    SignalingManager().checkActiveCalls(context);
  }

  void dispose() {
    _linkSubscription?.cancel();
  }
}

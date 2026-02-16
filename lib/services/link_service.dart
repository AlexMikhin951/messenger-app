import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'signaling_manager.dart'; // Добавь этот импорт

class LinkService {
  static final LinkService _instance = LinkService._internal();
  factory LinkService() => _instance;
  LinkService._internal();

  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;

  Future<void> subscribeToNotifications(String phone) async {
    final cleanPhone = phone.replaceAll(RegExp(r'\D'), '');
    final url = Uri.parse("https://ntfy.sh/family_call_$cleanPhone");

    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      debugPrint("Не удалось открыть ntfy");
    }
  }

  void init(BuildContext context) {
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
      _handleDeepLink(context, uri);
    });
    _checkInitialLink(context);
  }

  Future<void> _checkInitialLink(BuildContext context) async {
    final initialUri = await _appLinks.getInitialLink();
    if (initialUri != null) _handleDeepLink(context, initialUri);
  }

  // lib/services/link_service.dart

  void _handleDeepLink(BuildContext context, Uri uri) {
    // Нам не нужно делать Navigator.push здесь, если мы хотим,
    // чтобы SignalingManager сам управлял логикой входящего вызова.
    debugPrint("Приложение открыто через уведомление: ${uri.toString()}");

    // Можно просто вызвать проверку входящих звонков принудительно
    SignalingManager().checkActiveCalls(context);
  }

  void dispose() {
    _linkSubscription?.cancel();
  }
}

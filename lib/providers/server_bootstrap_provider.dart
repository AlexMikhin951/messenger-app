import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services_providers.dart';

enum BootstrapStatus { loading, authenticated, needsAuth, failed }

@immutable
class BootstrapState {
  const BootstrapState({
    this.status = BootstrapStatus.loading,
    this.message = 'Поиск сервера...',
  });

  final BootstrapStatus status;
  final String message;

  BootstrapState copyWith({
    BootstrapStatus? status,
    String? message,
  }) {
    return BootstrapState(
      status: status ?? this.status,
      message: message ?? this.message,
    );
  }
}

class ServerBootstrapNotifier extends Notifier<BootstrapState> {
  @override
  BootstrapState build() => const BootstrapState();

  Future<void> bootstrap() async {
    state = state.copyWith(
      status: BootstrapStatus.loading,
      message: 'Подключение к серверу...',
    );

    final api = ref.read(apiServiceProvider);
    final success = await api.autoInitialize();

    if (!success) {
      state = state.copyWith(
        status: BootstrapStatus.failed,
        message: 'Не удалось найти сервер.\nПроверьте интернет.',
      );
      return;
    }

    state = state.copyWith(message: 'Проверка авторизации...');

    final prefs = await SharedPreferences.getInstance();
    final savedPhone = prefs.getString('saved_phone');
    final savedPass = prefs.getString('saved_password');

    if (savedPhone != null && savedPass != null) {
      try {
        await api.pb
            .collection('users')
            .authWithPassword(savedPhone, savedPass);

        final signaling = ref.read(signalingManagerProvider);
        signaling.startHeartbeat();

        if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
          signaling.startListeningNotifications();
        }

        state = state.copyWith(status: BootstrapStatus.authenticated);
        return;
      } catch (e) {
        debugPrint('Авто-вход не удался: $e');
      }
    }

    state = state.copyWith(status: BootstrapStatus.needsAuth);
  }
}

final serverBootstrapProvider =
    NotifierProvider<ServerBootstrapNotifier, BootstrapState>(
  ServerBootstrapNotifier.new,
);

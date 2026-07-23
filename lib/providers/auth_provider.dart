import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'services_providers.dart';

@immutable
class AuthState {
  const AuthState({
    this.isLoading = false,
    this.showNameField = false,
    this.errorMessage,
    this.authenticatedPhone,
    this.authenticatedPassword,
  });

  final bool isLoading;
  final bool showNameField;
  final String? errorMessage;
  final String? authenticatedPhone;
  final String? authenticatedPassword;

  bool get isAuthenticated =>
      authenticatedPhone != null && authenticatedPassword != null;

  AuthState copyWith({
    bool? isLoading,
    bool? showNameField,
    String? errorMessage,
    bool clearError = false,
    String? authenticatedPhone,
    String? authenticatedPassword,
    bool clearAuth = false,
  }) {
    return AuthState(
      isLoading: isLoading ?? this.isLoading,
      showNameField: showNameField ?? this.showNameField,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      authenticatedPhone:
          clearAuth ? null : (authenticatedPhone ?? this.authenticatedPhone),
      authenticatedPassword: clearAuth
          ? null
          : (authenticatedPassword ?? this.authenticatedPassword),
    );
  }
}

class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() => const AuthState();

  ApiService get _api => ref.read(apiServiceProvider);

  Future<void> authenticate({
    required String rawPhone,
    String? name,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);

    String phone = rawPhone.trim().replaceAll(RegExp(r'[^\d]'), '');
    if (phone.length == 11 && phone.startsWith('8')) {
      phone = '7${phone.substring(1)}';
    }

    if (phone.isEmpty) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Введите номер телефона',
      );
      return;
    }

    final hiddenPassword = 'family_member_$phone';
    debugPrint('📡 Попытка входа: Пользователь=$phone');

    try {
      await _api.pb.collection('users').authWithPassword(phone, hiddenPassword);
      _onSuccess(phone, hiddenPassword);
    } catch (e) {
      debugPrint('ℹ️ Вход не удался, пробуем регистрацию. Ошибка: $e');

      if (!state.showNameField) {
        state = state.copyWith(
          isLoading: false,
          showNameField: true,
          errorMessage: 'Пользователь не найден. Введите имя для регистрации.',
        );
        return;
      }

      final trimmedName = name?.trim() ?? '';
      if (trimmedName.isEmpty) {
        state = state.copyWith(
          isLoading: false,
          errorMessage: 'Введите ваше имя',
        );
        return;
      }

      try {
        debugPrint('📝 Создание нового профиля: $phone');
        await _api.pb.collection('users').create(body: {
          'username': phone,
          'name': trimmedName,
          'password': hiddenPassword,
          'passwordConfirm': hiddenPassword,
        });

        await _api.pb
            .collection('users')
            .authWithPassword(phone, hiddenPassword);
        _onSuccess(phone, hiddenPassword);
      } catch (err) {
        debugPrint('❌ Ошибка регистрации/входа: $err');
        state = state.copyWith(
          isLoading: false,
          errorMessage:
              'Этот номер уже занят, но пароль не подошел. Очистите базу данных.',
        );
      }
    } finally {
      if (state.isLoading) {
        state = state.copyWith(isLoading: false);
      }
    }
  }

  void _onSuccess(String phone, String password) {
    state = state.copyWith(
      isLoading: false,
      authenticatedPhone: phone,
      authenticatedPassword: password,
    );
  }

  Future<void> completeAuthSideEffects() async {
    final phone = state.authenticatedPhone;
    final password = state.authenticatedPassword;
    if (phone == null || password == null) return;

    await _api.saveCredentials(phone, password);
  }

  void clearError() {
    if (state.errorMessage != null) {
      state = state.copyWith(clearError: true);
    }
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);

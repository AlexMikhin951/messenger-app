import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'services_providers.dart';

/// Запуск heartbeat, слушателя звонков и ntfy после входа.
class SignalingSessionNotifier extends Notifier<void> {
  @override
  void build() {}

  void startAfterLogin(BuildContext context) {
    final signaling = ref.read(signalingManagerProvider);
    signaling.startHeartbeat();
    signaling.initCallListener(context);

    if (!kIsWeb && Platform.isLinux) {
      signaling.startListeningNotifications();
    }
  }

  void startOnContactsOpen(BuildContext context) {
    final signaling = ref.read(signalingManagerProvider);
    signaling.initCallListener(context);
    signaling.checkActiveCalls(context);
    signaling.startHeartbeat();
  }

  Future<void> startWindowsNotifications() async {
    if (!kIsWeb && Platform.isWindows) {
      ref.read(signalingManagerProvider).startListeningNotifications();
    }
  }
}

final signalingSessionProvider =
    NotifierProvider<SignalingSessionNotifier, void>(
  SignalingSessionNotifier.new,
);

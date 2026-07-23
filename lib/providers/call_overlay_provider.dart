import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'services_providers.dart';

@immutable
class CallOverlayState {
  const CallOverlayState({
    this.isMinimized = false,
    this.isGroupCall = false,
    this.currentRoomId,
    this.currentReceiverId,
    this.groupRoomName,
    this.groupUserName,
    this.groupIdentity,
    this.groupMessageId,
  });

  final bool isMinimized;
  final bool isGroupCall;
  final String? currentRoomId;
  final String? currentReceiverId;
  final String? groupRoomName;
  final String? groupUserName;
  final String? groupIdentity;
  final String? groupMessageId;

  CallOverlayState copyWith({bool? isMinimized}) {
    return CallOverlayState(
      isMinimized: isMinimized ?? this.isMinimized,
      isGroupCall: isGroupCall,
      currentRoomId: currentRoomId,
      currentReceiverId: currentReceiverId,
      groupRoomName: groupRoomName,
      groupUserName: groupUserName,
      groupIdentity: groupIdentity,
      groupMessageId: groupMessageId,
    );
  }
}

class CallOverlayNotifier extends Notifier<CallOverlayState> {
  VoidCallback? _listener;

  @override
  CallOverlayState build() {
    final signaling = ref.watch(signalingManagerProvider);

    void syncFromSignaling() {
      state = CallOverlayState(
        isMinimized: signaling.isMinimized.value,
        isGroupCall: signaling.isGroupCall,
        currentRoomId: signaling.currentRoomId,
        currentReceiverId: signaling.currentReceiverId,
        groupRoomName: signaling.groupRoomName,
        groupUserName: signaling.groupUserName,
        groupIdentity: signaling.groupIdentity,
        groupMessageId: signaling.groupMessageId,
      );
    }

    _listener ??= syncFromSignaling;
    signaling.isMinimized.addListener(_listener!);
    ref.onDispose(() {
      signaling.isMinimized.removeListener(_listener!);
    });

    syncFromSignaling();
    return state;
  }

  void expandCall() {
    ref.read(signalingManagerProvider).isMinimized.value = false;
  }

  Future<void> hangUp() async {
    final signaling = ref.read(signalingManagerProvider);
    await signaling.hangUp(signaling.currentRoomId);
  }
}

final callOverlayProvider =
    NotifierProvider<CallOverlayNotifier, CallOverlayState>(
  CallOverlayNotifier.new,
);

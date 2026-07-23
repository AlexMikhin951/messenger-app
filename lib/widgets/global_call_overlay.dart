import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../main.dart';
import '../providers/call_overlay_provider.dart';
import '../screens/group_call_screen.dart';
import '../screens/video_call_screen.dart';

class GlobalCallOverlay extends ConsumerWidget {
  const GlobalCallOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overlay = ref.watch(callOverlayProvider);

    return Stack(
      children: [
        child,
        if (overlay.isMinimized)
          Positioned(
            right: 16,
            bottom: 100,
            child: Material(
              color: Colors.transparent,
              elevation: 10,
              child: GestureDetector(
                onTap: () {
                  ref.read(callOverlayProvider.notifier).expandCall();

                  final navigator =
                      FamilyMessengerApp.navigatorKey.currentState;
                  if (navigator == null) return;

                  if (overlay.isGroupCall) {
                    navigator.push(
                      MaterialPageRoute(
                        builder: (context) => GroupCallScreen(
                          roomName: overlay.groupRoomName ?? '',
                          userName: overlay.groupUserName ?? '',
                          identity: overlay.groupIdentity ?? '',
                          messageId: overlay.groupMessageId,
                        ),
                      ),
                    );
                  } else {
                    navigator.push(
                      MaterialPageRoute(
                        builder: (context) => VideoCallScreen(
                          receiverId: overlay.currentReceiverId ?? '',
                          roomId: overlay.currentRoomId,
                        ),
                      ),
                    );
                  }
                },
                child: Container(
                  width: 90,
                  height: 130,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E272E),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: overlay.isGroupCall
                          ? Colors.orangeAccent
                          : Colors.greenAccent,
                      width: 2,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black45,
                        blurRadius: 10,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 12),
                      Icon(
                        overlay.isGroupCall ? Icons.groups : Icons.videocam,
                        color: overlay.isGroupCall
                            ? Colors.orangeAccent
                            : Colors.greenAccent,
                        size: 32,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        overlay.isGroupCall ? 'Группа' : 'Звонок',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        width: double.infinity,
                        height: 40,
                        decoration: const BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.vertical(
                            bottom: Radius.circular(14),
                          ),
                        ),
                        child: InkWell(
                          onTap: () =>
                              ref.read(callOverlayProvider.notifier).hangUp(),
                          child: const Icon(Icons.call_end,
                              color: Colors.white, size: 24),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

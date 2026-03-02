import 'package:flutter/material.dart';
import '../services/signaling_manager.dart';
import '../screens/video_call_screen.dart';
import '../screens/group_call_screen.dart';
import '../main.dart'; // ВАЖНО: Импортируем main.dart для доступа к navigatorKey

class GlobalCallOverlay extends StatelessWidget {
  final Widget child;

  GlobalCallOverlay({super.key, required this.child});

  final SignalingManager _signaling = SignalingManager();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child, // Основное приложение

        ValueListenableBuilder<bool>(
          valueListenable: _signaling.isMinimized,
          builder: (context, isMinimized, _) {
            if (!isMinimized) return const SizedBox.shrink();

            final bool isGroup = _signaling.isGroupCall;

            return Positioned(
              right: 16,
              bottom: 100,
              child: Material(
                color: Colors.transparent,
                elevation: 10,
                child: GestureDetector(
                  onTap: () {
                    // РАЗВОРАЧИВАЕМ ЗВОНОК
                    _signaling.isMinimized.value = false;

                    // ИСПОЛЬЗУЕМ ГЛОБАЛЬНЫЙ НАВИГАТОР
                    final navigator =
                        FamilyMessengerApp.navigatorKey.currentState;
                    if (navigator != null) {
                      if (isGroup) {
                        navigator.push(
                          MaterialPageRoute(
                            builder: (context) => GroupCallScreen(
                              roomName: _signaling.groupRoomName ?? '',
                              userName: _signaling.groupUserName ?? '',
                              identity: _signaling.groupIdentity ?? '',
                              messageId: _signaling.groupMessageId,
                            ),
                          ),
                        );
                      } else {
                        navigator.push(
                          MaterialPageRoute(
                            builder: (context) => VideoCallScreen(
                              receiverId: _signaling.currentReceiverId ?? '',
                              roomId: _signaling.currentRoomId,
                            ),
                          ),
                        );
                      }
                    }
                  },
                  child: Container(
                    width: 90,
                    height: 130,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E272E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: isGroup
                              ? Colors.orangeAccent
                              : Colors.greenAccent,
                          width: 2),
                      boxShadow: const [
                        BoxShadow(
                            color: Colors.black45,
                            blurRadius: 10,
                            spreadRadius: 2)
                      ],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 12),
                        Icon(isGroup ? Icons.groups : Icons.videocam,
                            color: isGroup
                                ? Colors.orangeAccent
                                : Colors.greenAccent,
                            size: 32),
                        const SizedBox(height: 8),
                        Text(isGroup ? "Группа" : "Звонок",
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.bold)),
                        const Spacer(),

                        // КНОПКА СБРОСА ПРЯМО НА ВИДЖЕТЕ
                        Container(
                          width: double.infinity,
                          height: 40,
                          decoration: const BoxDecoration(
                            color: Colors.redAccent,
                            borderRadius: BorderRadius.vertical(
                                bottom: Radius.circular(14)),
                          ),
                          child: InkWell(
                            onTap: () {
                              _signaling.hangUp(_signaling.currentRoomId);
                            },
                            child: const Icon(Icons.call_end,
                                color: Colors.white, size: 24),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

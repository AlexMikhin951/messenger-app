import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/signaling_manager.dart';
import '../services/group_chat_service.dart';
import '../services/livekit_service.dart';
import '../services/api_service.dart';
export '../services/api_service.dart';
export '../services/group_chat_service.dart';
export '../services/signaling_manager.dart';
export '../services/livekit_service.dart';

final apiServiceProvider = Provider<ApiService>((ref) => ApiService());

final signalingManagerProvider =
    Provider<SignalingManager>((ref) => SignalingManager());

final groupChatServiceProvider = Provider<GroupChatService>((ref) {
  return GroupChatService(ref.watch(apiServiceProvider));
});

final liveKitServiceProvider = Provider<LiveKitService>((ref) {
  return LiveKitService(ref.watch(apiServiceProvider));
});

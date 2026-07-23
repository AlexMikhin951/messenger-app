import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@immutable
class ChatComposerState {
  const ChatComposerState({
    this.isUploading = false,
    this.isRecording = false,
    this.recordedFilePath,
    this.isPlayingPreview = false,
    this.editingMessageId,
    this.downloadingFiles = const {},
  });

  final bool isUploading;
  final bool isRecording;
  final String? recordedFilePath;
  final bool isPlayingPreview;
  final String? editingMessageId;
  final Map<String, bool> downloadingFiles;

  ChatComposerState copyWith({
    bool? isUploading,
    bool? isRecording,
    String? recordedFilePath,
    bool clearRecordedFile = false,
    bool? isPlayingPreview,
    String? editingMessageId,
    bool clearEditing = false,
    Map<String, bool>? downloadingFiles,
  }) {
    return ChatComposerState(
      isUploading: isUploading ?? this.isUploading,
      isRecording: isRecording ?? this.isRecording,
      recordedFilePath:
          clearRecordedFile ? null : (recordedFilePath ?? this.recordedFilePath),
      isPlayingPreview: isPlayingPreview ?? this.isPlayingPreview,
      editingMessageId:
          clearEditing ? null : (editingMessageId ?? this.editingMessageId),
      downloadingFiles: downloadingFiles ?? this.downloadingFiles,
    );
  }
}

class ChatComposerNotifier extends Notifier<ChatComposerState> {
  ChatComposerNotifier(this.chatKey);

  @override
  ChatComposerState build() => const ChatComposerState();

  void setUploading(bool value) {
    state = state.copyWith(isUploading: value);
  }

  void setRecording(bool value, {String? filePath}) {
    state = state.copyWith(
      isRecording: value,
      recordedFilePath: filePath,
      clearRecordedFile: filePath == null && !value,
    );
  }

  void setPlayingPreview(bool value) {
    state = state.copyWith(isPlayingPreview: value);
  }

  void startEditing(String messageId) {
    state = state.copyWith(editingMessageId: messageId);
  }

  void clearEditing() {
    state = state.copyWith(clearEditing: true);
  }

  void setDownloading(String messageId, bool value) {
    final files = Map<String, bool>.from(state.downloadingFiles);
    if (value) {
      files[messageId] = true;
    } else {
      files.remove(messageId);
    }
    state = state.copyWith(downloadingFiles: files);
  }
}

final chatComposerProvider = NotifierProvider.family<
    ChatComposerNotifier, ChatComposerState, String>(
  ChatComposerNotifier.new,
);

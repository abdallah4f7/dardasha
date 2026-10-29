import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n.dart';
import '../services/api.dart';

void toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
}

/// Shows a friendly error for anything thrown by a user action.
void showError(BuildContext context, Object e) {
  final l = L.of(context);
  final text = switch (e) {
    FileTooLarge() => l.t('tooLarge'),
    _ => '${l.t('error')}: ${e.toString().split('\n').first}',
  };
  toast(context, text);
}

String formatTime(BuildContext context, DateTime t) =>
    DateFormat.jm(Localizations.localeOf(context).languageCode).format(t);

String formatChatDate(BuildContext context, DateTime t) {
  final l = L.of(context);
  final now = DateTime.now();
  final d = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  if (d == today) return formatTime(context, t);
  if (d == today.subtract(const Duration(days: 1))) return l.t('yesterday');
  return DateFormat.yMd(Localizations.localeOf(context).languageCode).format(t);
}

String formatDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
}

String contentTypeFor(String path) {
  final ext = path.split('.').last.toLowerCase();
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    '3gp' => 'video/3gpp',
    'm4a' => 'audio/mp4',
    'aac' => 'audio/aac',
    'mp3' => 'audio/mpeg',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'zip' => 'application/zip',
    'doc' => 'application/msword',
    'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'apk' => 'application/vnd.android.package-archive',
    _ => 'application/octet-stream',
  };
}

/// Short label for the chat list ("📷 Photo" etc).
String lastMessageLabel(L l, String? type, String? text) => switch (type) {
  'image' => '📷 ${l.t('photo')}',
  'video' => '🎬 ${l.t('video')}',
  'voice' => '🎤 ${l.t('voiceMessage')}',
  'sticker' => '✨ ${l.t('sticker')}',
  'call' => '📞 ${l.t('callMsg')}',
  'file' => '📎 ${text ?? l.t('file')}',
  _ => text ?? '',
};

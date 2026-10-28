import 'package:chat/models.dart';
import 'package:chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Message msg(String type, {String? content, String? media, Map<String, dynamic> meta = const {}}) => Message(
  id: type, conversationId: 'c', senderId: 'me', type: type, content: content, mediaUrl: media,
  meta: meta, createdAt: DateTime.now());

void main() {
  final cases = {
    'sticker-emoji': msg('sticker', content: '😂'),
    'sticker-url': msg('sticker', media: 'https://example.com/s.png'),
    'call': msg('call', meta: {'video': false, 'seconds': 0}),
    'video': msg('video', media: 'https://example.com/v.mp4'),
    'text-reply': msg('text', content: 'نقا', meta: {'reply': {'id': 'x', 'name': 'abood', 'text': 'hi', 'type': 'text'}}),
    'text-edited': msg('text', content: 'hey', meta: {'edited': true}),
  };
  for (final e in cases.entries) {
    for (final mine in [true, false]) {
      testWidgets('${e.key} mine=$mine', (t) async {
        await t.pumpWidget(MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
          home: Scaffold(body: ListView(reverse: true, children: [
            MessageBubble(message: e.value, mine: mine, onReply: (_) {}, onReact: (_) {}, onEdit: (_) {}, onDelete: (_) {}),
          ])),
        ));
        await t.pump(const Duration(milliseconds: 100));
      });
    }
  }
}

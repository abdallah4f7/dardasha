import 'package:chat/services/calls.dart';
import 'package:chat/widgets/call_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('minimized call bubble opens the call when tapped and can be dragged', (t) async {
    final s = CallSession(callId: 'c', video: false, outgoing: true, core: const {'me', 'p'});
    var opened = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: Stack(children: [CallBubble(session: s, onOpen: () => opened++, onGone: () {})])),
    ));
    await t.pump();
    expect(find.text('…'), findsOneWidget);

    // Dropped past the middle, it settles against the left edge, lower down.
    await t.drag(find.byType(Material).last, const Offset(-500, 150));
    await t.pump();
    final pos = t.getTopLeft(find.byType(Material).last);
    expect(pos.dx, 8);
    expect(pos.dy, greaterThan(150));

    await t.tap(find.byType(Material).last);
    expect(opened, 1);
  });
}

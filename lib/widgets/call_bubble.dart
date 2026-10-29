import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/calls.dart';
import 'avatar.dart';
import 'common.dart';

/// A minimized call: floats above every page, can be dragged around, and
/// opens the call screen again when tapped.
class CallBubble extends StatefulWidget {
  const CallBubble({super.key, required this.session, required this.onOpen, required this.onGone});

  final CallSession session;
  final VoidCallback onOpen;

  /// The call ended while minimized.
  final VoidCallback onGone;

  @override
  State<CallBubble> createState() => _CallBubbleState();
}

class _CallBubbleState extends State<CallBubble> {
  CallSession get s => widget.session;
  Offset? _pos;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    s.addListener(_onChange);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  void _onChange() {
    if (s.state == CallState.ended) {
      Future.delayed(const Duration(milliseconds: 1200), widget.onGone);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
    s.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final video = s.remoteVideo && s.state == CallState.connected && s.remoteRenderer.textureId != null;
    final size = video ? const Size(96, 136) : const Size(84, 104);
    final maxX = media.size.width - size.width - 8;
    final maxY = media.size.height - size.height - media.padding.bottom - 8;
    final minY = media.padding.top + 8;
    final raw = _pos ?? Offset(maxX, media.padding.top + 72);
    final pos = Offset(raw.dx.clamp(8, maxX), raw.dy.clamp(minY, maxY));
    final status = switch (s.state) {
      CallState.connected => formatDuration(DateTime.now().difference(s.connectedAt!)),
      CallState.ended => '✕',
      _ => '…',
    };

    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: GestureDetector(
        onTap: widget.onOpen,
        onPanUpdate: (d) => setState(() => _pos = (_pos ?? pos) + d.delta),
        // Settle against the nearest side, out of the way.
        onPanEnd: (_) => setState(() {
          final p = _pos ?? pos;
          _pos = Offset(p.dx + size.width / 2 < media.size.width / 2 ? 8 : maxX, p.dy.clamp(minY, maxY));
        }),
        child: Material(
          elevation: 8,
          color: const Color(0xFF0E1222),
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: SizedBox.fromSize(
            size: size,
            child: Stack(
              children: [
                if (video)
                  Positioned.fill(
                    child: RTCVideoView(s.remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                  )
                else
                  Align(
                    alignment: const Alignment(0, -.35),
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: s.state == CallState.ended ? Colors.redAccent : Colors.greenAccent,
                          width: 2,
                        ),
                      ),
                      child: Avatar(name: s.peer.displayName, url: s.peer.avatarUrl, radius: 26),
                    ),
                  ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    color: video ? Colors.black45 : null,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(s.muted ? Icons.mic_off : Icons.call, size: 13, color: Colors.white70),
                        const SizedBox(width: 4),
                        Text(
                          status,
                          textDirection: TextDirection.ltr,
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../l10n.dart';
import '../services/calls.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';

class CallPage extends StatefulWidget {
  const CallPage({super.key, required this.session});

  final CallSession session;

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  CallSession get s => widget.session;
  Timer? _ticker;
  Timer? _vibrate;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    s.addListener(_onChange);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    if (s.outgoing) {
      s.startOutgoing();
    } else {
      _vibrate = Timer.periodic(const Duration(milliseconds: 1500), (_) => HapticFeedback.heavyImpact());
    }
  }

  void _onChange() {
    if (s.state != CallState.ringing) _vibrate?.cancel();
    if (s.state == CallState.ended && !_closing) {
      _closing = true;
      Future.delayed(const Duration(milliseconds: 1400), () {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _vibrate?.cancel();
    s.removeListener(_onChange);
    if (s.state != CallState.ended) s.hangup();
    s.disposeRenderers();
    super.dispose();
  }

  String _status(L l) => switch (s.state) {
    CallState.ringing => s.outgoing ? l.t('calling') : l.t(s.video ? 'incomingVideo' : 'incomingVoice'),
    CallState.connecting => l.t('connecting'),
    CallState.connected => formatDuration(DateTime.now().difference(s.connectedAt!)),
    CallState.ended => l.t(s.endReason ?? 'callEnded'),
  };

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final showRemoteVideo = s.video && s.hasRemoteVideo && s.state == CallState.connected;
    final incomingRinging = !s.outgoing && s.state == CallState.ringing;

    return PopScope(
      canPop: s.state == CallState.ended,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) s.hangup();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0E1222),
        body: Stack(
          children: [
            if (showRemoteVideo)
              Positioned.fill(
                child: RTCVideoView(s.remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
              ),
            SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 48),
                  if (!showRemoteVideo) ...[
                    Avatar(name: s.peer.displayName, url: s.peer.avatarUrl, radius: 56),
                    const SizedBox(height: 20),
                  ],
                  Text(
                    s.peer.displayName,
                    style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(_status(l), style: const TextStyle(color: Colors.white70, fontSize: 16)),
                  const Spacer(),
                  if (incomingRinging)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 48),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _RoundButton(
                            icon: Icons.call_end,
                            color: Colors.red,
                            label: l.t('decline'),
                            onTap: s.decline,
                          ),
                          _RoundButton(
                            icon: s.video ? Icons.videocam : Icons.call,
                            color: Colors.green,
                            label: l.t('accept'),
                            onTap: s.accept,
                          ),
                        ],
                      ),
                    )
                  else if (s.state != CallState.ended)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 40),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 18,
                        runSpacing: 18,
                        children: [
                          _RoundButton(
                            icon: s.muted ? Icons.mic_off : Icons.mic,
                            color: s.muted ? Colors.white : Colors.white24,
                            iconColor: s.muted ? Colors.black : Colors.white,
                            onTap: s.toggleMute,
                          ),
                          _RoundButton(
                            icon: s.speaker ? Icons.volume_up : Icons.hearing,
                            color: s.speaker ? Colors.white : Colors.white24,
                            iconColor: s.speaker ? Colors.black : Colors.white,
                            onTap: s.toggleSpeaker,
                          ),
                          if (s.video) ...[
                            _RoundButton(
                              icon: s.cameraOff ? Icons.videocam_off : Icons.videocam,
                              color: s.cameraOff ? Colors.white : Colors.white24,
                              iconColor: s.cameraOff ? Colors.black : Colors.white,
                              onTap: s.toggleCamera,
                            ),
                            _RoundButton(icon: Icons.cameraswitch, color: Colors.white24, onTap: s.switchCamera),
                          ],
                          _RoundButton(icon: Icons.call_end, color: Colors.red, onTap: s.hangup),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (s.video && !s.cameraOff && s.state != CallState.ended && s.localRenderer.textureId != null)
              PositionedDirectional(
                top: MediaQuery.paddingOf(context).top + 16,
                end: 16,
                width: 110,
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: RTCVideoView(
                    s.localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.label,
    this.iconColor = Colors.white,
  });

  final IconData icon;
  final Color color;
  final Color iconColor;
  final VoidCallback onTap;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Icon(icon, color: iconColor, size: 30),
            ),
          ),
        ),
        if (label != null) ...[const SizedBox(height: 8), Text(label!, style: const TextStyle(color: Colors.white))],
      ],
    );
  }
}

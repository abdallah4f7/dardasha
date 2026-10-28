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
    final showRemoteVideo = s.remoteVideo && s.state == CallState.connected;
    final incomingRinging = !s.outgoing && s.state == CallState.ringing;
    final showLocalVideo = s.cameraOn && s.state != CallState.ended && s.localRenderer.textureId != null;

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
                child: RTCVideoView(
                  s.remoteRenderer,
                  // A shared screen must be seen whole; a face can be cropped.
                  objectFit: s.remoteScreen
                      ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
                      : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            Positioned.fill(
              child: SafeArea(
                child: Column(
                  children: [
                    const SizedBox(height: 48),
                    if (!showRemoteVideo) ...[
                      Avatar(name: s.peer.displayName, url: s.peer.avatarUrl, radius: 56),
                      const SizedBox(height: 20),
                    ],
                    Text(
                      s.peer.displayName,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(_status(l), style: const TextStyle(color: Colors.white70, fontSize: 16)),
                    if (s.sharingScreen) ...[
                      const SizedBox(height: 12),
                      Chip(
                        avatar: const Icon(Icons.screen_share, size: 18),
                        label: Text(l.t('sharingScreen')),
                      ),
                    ],
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
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 14,
                          runSpacing: 14,
                          children: [
                            _RoundButton(
                              icon: s.muted ? Icons.mic_off : Icons.mic,
                              active: s.muted,
                              onTap: s.toggleMute,
                            ),
                            _RoundButton(
                              icon: s.speaker ? Icons.volume_up : Icons.hearing,
                              active: s.speaker,
                              onTap: s.toggleSpeaker,
                            ),
                            if (s.canShareVideo) ...[
                              _RoundButton(
                                icon: s.cameraOn ? Icons.videocam : Icons.videocam_off,
                                active: s.cameraOn,
                                onTap: s.toggleCamera,
                              ),
                              if (s.cameraOn) _RoundButton(icon: Icons.cameraswitch, onTap: s.switchCamera),
                              _RoundButton(
                                icon: s.sharingScreen ? Icons.stop_screen_share : Icons.screen_share,
                                active: s.sharingScreen,
                                onTap: s.toggleScreenShare,
                              ),
                            ],
                            _RoundButton(icon: Icons.call_end, color: Colors.red, onTap: s.hangup),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (showLocalVideo)
              PositionedDirectional(
                top: MediaQuery.paddingOf(context).top + 16,
                end: 16,
                width: 110,
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: RTCVideoView(
                    s.localRenderer,
                    mirror: s.frontCamera,
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
  const _RoundButton({required this.icon, required this.onTap, this.color, this.active = false, this.label});

  final IconData icon;

  /// Fixed color (hang up / answer). Otherwise white when [active], translucent when not.
  final Color? color;
  final bool active;
  final VoidCallback onTap;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final inverted = color == null && active;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color ?? (active ? Colors.white : Colors.white24),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Icon(icon, color: inverted ? Colors.black : Colors.white, size: 28),
            ),
          ),
        ),
        if (label != null) ...[const SizedBox(height: 8), Text(label!, style: const TextStyle(color: Colors.white))],
      ],
    );
  }
}

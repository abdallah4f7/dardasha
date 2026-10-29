import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:just_audio/just_audio.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import '../services/calls.dart';
import '../services/push.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';
import 'new_chat_page.dart';
import 'user_page.dart';

class CallPage extends StatefulWidget {
  const CallPage({super.key, required this.session});

  final CallSession session;

  @override
  State<CallPage> createState() => _CallPageState();
}

const _screen = MethodChannel('dardasha/screen');

class _CallPageState extends State<CallPage> with WidgetsBindingObserver {
  CallSession get s => widget.session;
  Timer? _ticker;
  Timer? _vibrate;
  final _tone = AudioPlayer();
  bool _toneLoaded = false;
  bool _closing = false;
  bool _minimized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    s.addListener(_onChange);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    if (s.outgoing) s.startOutgoing();
    _showOnLock(true);
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) _ring();
  }

  /// A call that arrives while the app is in the background opens this page out of
  /// sight; the notification rings then, and this screen only once it is seen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ring();
    } else if (state == AppLifecycleState.paused) {
      _silence();
    }
  }

  void _showOnLock(bool on) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _screen.invokeMethod('showOnLock', on).catchError((_) {});
    }
  }

  /// The call goes on in a floating bubble; tapping it brings this screen back.
  void _minimize() {
    _minimized = true;
    _showOnLock(false);
    CallService.instance.minimize(s);
    Navigator.of(context).pop();
  }

  /// Dardasha's ring for an incoming call, the plain ringback tone while calling out.
  Future<void> _ring() async {
    if (s.state != CallState.ringing) return;
    if (!s.outgoing) {
      Push.cancelCall(); // the screen rings now, not the notification
      _vibrate ??= Timer.periodic(const Duration(milliseconds: 1500), (_) => HapticFeedback.heavyImpact());
    }
    try {
      if (!_toneLoaded) {
        _toneLoaded = true;
        await _tone.setAsset(s.outgoing ? 'assets/sounds/ringback.wav' : 'assets/sounds/ring.wav');
        await _tone.setLoopMode(LoopMode.one);
      }
      if (s.state == CallState.ringing) await _tone.play();
    } catch (_) {} // the browser may refuse to play before the page is touched
  }

  void _silence() {
    _vibrate?.cancel();
    _vibrate = null;
    _tone.pause(); // not stop(): that unloads the tone, and ringing may resume
    _tone.seek(Duration.zero);
  }

  void _onChange() {
    if (s.state != CallState.ringing) _silence();
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
    _tone.dispose();
    WidgetsBinding.instance.removeObserver(this);
    s.removeListener(_onChange);
    if (!_minimized) _showOnLock(false);
    if (!_minimized) {
      if (s.state != CallState.ended) s.hangup();
      s.disposeRenderers();
    }
    super.dispose();
  }

  /// Long-press on someone: their profile, and removing them when allowed.
  Future<void> _personMenu(Profile p) async {
    final l = L.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Avatar(name: p.displayName, url: p.avatarUrl, radius: 18),
              title: Text(p.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(l.t('viewProfile')),
              onTap: () => Navigator.pop(c, 'profile'),
            ),
            if (s.canRemove(p.id))
              ListTile(
                leading: Icon(Icons.person_remove_outlined, color: Theme.of(c).colorScheme.error),
                title: Text(l.t('removeFromCall'), style: TextStyle(color: Theme.of(c).colorScheme.error)),
                onTap: () => Navigator.pop(c, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'profile':
        final full = await Api.profile(p.id).catchError((_) => null) ?? p;
        if (mounted) Navigator.of(context).push(MaterialPageRoute(builder: (_) => UserPage(user: full)));
      case 'remove':
        s.remove(p.id);
    }
  }

  /// Rings more people into the call: friends, or anyone found by their username.
  Future<void> _addPeople() async {
    final ids = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(builder: (_) => NewChatPage(pickMany: true, exclude: {myId, ...s.peers.keys})),
    );
    for (final id in ids ?? const <String>[]) {
      final p = await Api.profile(id).catchError((_) => null);
      if (p != null) await s.invite(p);
    }
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
    final incomingRinging = !s.outgoing && s.state == CallState.ringing;
    // More than one other person (or any group call): everyone gets a tile.
    final grid = !incomingRinging && (s.isGroup || s.peers.length > 1);
    final showRemoteVideo = !grid && s.remoteVideo && s.state == CallState.connected;
    final title = s.isGroup ? (s.groupName ?? l.t('groupCall')) : s.peer.displayName;
    final showLocalVideo = s.cameraOn && s.state != CallState.ended && s.localRenderer.textureId != null;

    return PopScope(
      canPop: s.state == CallState.ended,
      onPopInvokedWithResult: (didPop, _) {
        // Back declines a call that is still ringing in, and minimizes any other.
        if (!didPop) incomingRinging ? s.hangup() : _minimize();
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
                    SizedBox(
                      height: 48,
                      child: incomingRinging || s.state == CallState.ended
                          ? null
                          : Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: IconButton(
                                tooltip: l.t('minimize'),
                                icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 32),
                                onPressed: _minimize,
                              ),
                            ),
                    ),
                    if (!showRemoteVideo && !grid) ...[
                      GestureDetector(
                        onLongPress: incomingRinging ? null : () => _personMenu(s.peer),
                        child: Avatar(name: s.peer.displayName, url: s.peer.avatarUrl, radius: 56),
                      ),
                      const SizedBox(height: 20),
                    ],
                    GestureDetector(
                      onLongPress: incomingRinging || grid ? null : () => _personMenu(s.peer),
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (incomingRinging && s.isGroup) ...[
                      const SizedBox(height: 4),
                      Text(s.peer.displayName, style: const TextStyle(color: Colors.white70, fontSize: 15)),
                    ],
                    const SizedBox(height: 8),
                    Text(_status(l), style: const TextStyle(color: Colors.white70, fontSize: 16)),
                    if (s.sharingScreen) ...[
                      const SizedBox(height: 12),
                      Chip(
                        avatar: const Icon(Icons.screen_share, size: 18),
                        label: Text(l.t('sharingScreen')),
                      ),
                    ],
                    if (grid)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: _ParticipantGrid(session: s, onLongPress: _personMenu),
                        ),
                      )
                    else
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
                            if (!kIsWeb) // the browser chooses the speaker
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
                            if (s.canInvite) _RoundButton(icon: Icons.person_add_alt_1, onTap: _addPeople),
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

/// Everyone else in a group call: their video when they send it, otherwise their picture.
class _ParticipantGrid extends StatelessWidget {
  const _ParticipantGrid({required this.session, required this.onLongPress});

  final CallSession session;
  final void Function(Profile) onLongPress;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final people = session.peers.values.toList();
    return LayoutBuilder(
      builder: (_, box) {
        final columns = people.length <= 1 ? 1 : 2;
        final rows = (people.length / columns).ceil().clamp(1, 99);
        const gap = 10.0;
        final tileW = (box.maxWidth - gap * (columns - 1)) / columns;
        final tileH = ((box.maxHeight - gap * (rows - 1)) / rows).clamp(120.0, 420.0);
        return SingleChildScrollView(
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            alignment: WrapAlignment.center,
            children: [
              for (final p in people)
                GestureDetector(
                  onLongPress: () => onLongPress(p.profile),
                  child: Container(
                    width: tileW,
                    height: tileH,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(16)),
                    child: Stack(
                      children: [
                        if (p.remoteVideo && p.state == PeerState.connected && p.renderer.textureId != null)
                          Positioned.fill(
                            child: RTCVideoView(
                              p.renderer,
                              objectFit: p.remoteScreen
                                  ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
                                  : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                            ),
                          )
                        else
                          Center(
                            child: Opacity(
                              opacity: p.state == PeerState.connected ? 1 : .5,
                              child: Avatar(name: p.profile.displayName, url: p.profile.avatarUrl, radius: 36),
                            ),
                          ),
                        PositionedDirectional(
                          start: 8,
                          end: 8,
                          bottom: 8,
                          child: Text(
                            [
                              p.profile.displayName,
                              if (p.state == PeerState.ringing) l.t('ringing'),
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              shadows: [Shadow(blurRadius: 4)],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
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

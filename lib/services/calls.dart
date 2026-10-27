import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../models.dart';
import '../pages/call_page.dart';
import 'api.dart';

/// Signaling: every signed-in user listens on broadcast channel `calls:<their id>`.
/// To reach someone we join their channel and broadcast a `signal` event.
class CallService {
  CallService._();
  static final instance = CallService._();

  late GlobalKey<NavigatorState> navigatorKey;
  RealtimeChannel? _inbox;
  final Map<String, Future<RealtimeChannel>> _outbox = {};
  CallSession? active;

  void start() {
    if (_inbox != null) return;
    _inbox = db.channel('calls:$myId').onBroadcast(event: 'signal', callback: _onSignal).subscribe();
  }

  Future<void> stop() async {
    active?.hangup();
    if (_inbox != null) await db.removeChannel(_inbox!);
    _inbox = null;
    for (final ch in _outbox.values) {
      await db.removeChannel(await ch);
    }
    _outbox.clear();
  }

  Future<RealtimeChannel> _channelTo(String userId) {
    return _outbox.putIfAbsent(userId, () {
      final done = Completer<RealtimeChannel>();
      final ch = db.channel('calls:$userId');
      ch.subscribe((status, _) {
        if (status == RealtimeSubscribeStatus.subscribed && !done.isCompleted) done.complete(ch);
      });
      return done.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          _outbox.remove(userId);
          throw TimeoutException('signaling');
        },
      );
    });
  }

  Future<void> send(String to, Map<String, dynamic> data) async {
    final ch = await _channelTo(to);
    await ch.sendBroadcastMessage(
      event: 'signal',
      payload: {
        'data': {...data, 'to': to, 'from': myId},
      },
    );
  }

  void _onSignal(Map<String, dynamic> msg) {
    final raw = msg['data'] ?? (msg['payload'] is Map ? (msg['payload'] as Map)['data'] : null);
    if (raw is! Map) return;
    final data = Map<String, dynamic>.from(raw);
    if (data['to'] != myId) return;
    final callId = data['callId'] as String?;
    if (callId == null) return;

    if (data['type'] == 'offer') {
      if (active != null && active!.callId != callId) {
        send(data['from'] as String, {'type': 'busy', 'callId': callId});
        return;
      }
      final peer = Profile(
        id: data['from'] as String,
        username: '',
        displayName: data['fromName'] as String? ?? '',
        avatarUrl: data['fromAvatar'] as String?,
      );
      final s = CallSession(callId: callId, peer: peer, video: data['video'] == true, outgoing: false)
        ..remoteOffer = data['sdp'] as String?;
      active = s;
      navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => CallPage(session: s)));
      return;
    }
    if (active?.callId == callId) active!.handleSignal(data);
  }

  /// Starts an outgoing call and opens the call screen.
  Future<void> call(BuildContext context, Profile peer, {required bool video, String? conversationId}) async {
    if (active != null) return;
    final s = CallSession(
      callId: const Uuid().v4(),
      peer: peer,
      video: video,
      outgoing: true,
      conversationId: conversationId,
    );
    active = s;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CallPage(session: s)));
  }
}

enum CallState { ringing, connecting, connected, ended }

class CallSession extends ChangeNotifier {
  CallSession({
    required this.callId,
    required this.peer,
    required this.video,
    required this.outgoing,
    this.conversationId,
  });

  final String callId;
  final Profile peer;
  final bool video;
  final bool outgoing;
  final String? conversationId;

  CallState state = CallState.ringing;
  String? endReason; // l10n key
  String? remoteOffer;
  DateTime? connectedAt;

  bool muted = false;
  bool cameraOff = false;
  late bool speaker = video;

  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();
  bool hasRemoteVideo = false;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  bool _remoteSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];
  Timer? _ringTimeout;

  CallService get _svc => CallService.instance;

  void _set(CallState s) {
    if (state == CallState.ended) return;
    state = s;
    notifyListeners();
  }

  Future<void> _setup() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video ? {'facingMode': 'user'} : false,
    });
    localRenderer.srcObject = _local;

    final pc = await createPeerConnection({'iceServers': iceServers, 'sdpSemantics': 'unified-plan'});
    _pc = pc;
    for (final t in _local!.getTracks()) {
      await pc.addTrack(t, _local!);
    }
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _svc.send(peer.id, {'type': 'candidate', 'callId': callId, 'candidate': c.toMap()});
    };
    pc.onTrack = (e) {
      if (e.streams.isEmpty) return;
      remoteRenderer.srcObject = e.streams.first;
      if (e.track.kind == 'video') hasRemoteVideo = true;
      notifyListeners();
    };
    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        connectedAt ??= DateTime.now();
        _set(CallState.connected);
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        hangup();
      }
    };
    await Helper.setSpeakerphoneOn(speaker);
    notifyListeners();
  }

  Future<void> startOutgoing() async {
    try {
      await _setup();
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      final me = await Api.profile(myId);
      await _svc.send(peer.id, {
        'type': 'offer',
        'callId': callId,
        'sdp': offer.sdp,
        'video': video,
        'fromName': me?.displayName,
        'fromAvatar': me?.avatarUrl,
      });
      _ringTimeout = Timer(const Duration(seconds: 45), () => hangup(reason: 'noAnswer'));
    } catch (_) {
      _end('error');
    }
  }

  Future<void> accept() async {
    _set(CallState.connecting);
    try {
      await _setup();
      await _pc!.setRemoteDescription(RTCSessionDescription(remoteOffer, 'offer'));
      await _flushCandidates();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await _svc.send(peer.id, {'type': 'answer', 'callId': callId, 'sdp': answer.sdp});
    } catch (_) {
      hangup(reason: 'error');
    }
  }

  void decline() {
    _svc.send(peer.id, {'type': 'reject', 'callId': callId});
    _end('declined');
  }

  void hangup({String reason = 'callEnded'}) {
    if (state == CallState.ended) return;
    _svc.send(peer.id, {'type': 'end', 'callId': callId}).catchError((_) {});
    _end(reason);
  }

  Future<void> handleSignal(Map<String, dynamic> d) async {
    switch (d['type']) {
      case 'answer':
        _ringTimeout?.cancel();
        _set(CallState.connecting);
        await _pc?.setRemoteDescription(RTCSessionDescription(d['sdp'] as String?, 'answer'));
        await _flushCandidates();
      case 'candidate':
        final c = Map<String, dynamic>.from(d['candidate'] as Map);
        final cand = RTCIceCandidate(c['candidate'] as String?, c['sdpMid'] as String?, c['sdpMLineIndex'] as int?);
        if (_pc != null && _remoteSet) {
          await _pc!.addCandidate(cand);
        } else {
          _pendingCandidates.add(cand);
        }
      case 'reject':
        _end('declined');
      case 'busy':
        _end('busy');
      case 'end':
        _end('callEnded');
    }
  }

  Future<void> _flushCandidates() async {
    _remoteSet = true;
    for (final c in _pendingCandidates) {
      await _pc!.addCandidate(c);
    }
    _pendingCandidates.clear();
  }

  void toggleMute() {
    muted = !muted;
    for (final t in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  void toggleCamera() {
    cameraOff = !cameraOff;
    for (final t in _local?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !cameraOff;
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final tracks = _local?.getVideoTracks() ?? [];
    if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    await Helper.setSpeakerphoneOn(speaker);
    notifyListeners();
  }

  void _end(String reason) {
    if (state == CallState.ended) return;
    _ringTimeout?.cancel();
    endReason = reason;
    state = CallState.ended;
    notifyListeners();
    if (_svc.active == this) _svc.active = null;

    for (final t in _local?.getTracks() ?? <MediaStreamTrack>[]) {
      t.stop();
    }
    _local?.dispose();
    _pc?.close();

    if (outgoing && conversationId != null) {
      final seconds = connectedAt == null ? 0 : DateTime.now().difference(connectedAt!).inSeconds;
      Api.send(
        conversationId!,
        type: 'call',
        meta: {'video': video, 'seconds': seconds},
      ).catchError((_) => <String, dynamic>{});
    }
  }

  Future<void> disposeRenderers() async {
    for (final r in [localRenderer, remoteRenderer]) {
      try {
        if (r.textureId != null) r.srcObject = null;
        await r.dispose();
      } catch (_) {}
    }
  }
}

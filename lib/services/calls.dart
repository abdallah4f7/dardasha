import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../models.dart';
import '../pages/call_page.dart';
import 'api.dart';
import 'push.dart';

/// Signaling: every signed-in user listens on broadcast channel `calls:<their id>`.
/// To reach someone we join their channel and broadcast a `signal` event.
class CallService {
  CallService._();
  static final instance = CallService._();

  late GlobalKey<NavigatorState> navigatorKey;
  RealtimeChannel? _inbox;
  final Map<String, Future<RealtimeChannel>> _outbox = {};
  CallSession? active;

  /// Offers are re-sent while ringing (so a callee who opens the app from the
  /// push notification still gets them); this keeps each call from ringing twice.
  final Set<String> _seenCalls = {};

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
      if (!_seenCalls.add(callId)) return;
      if (active != null) {
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

/// Keeps Android's screen capture alive (it needs a foreground service).
const _screenService = MethodChannel('dardasha/screen');

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
  late bool cameraOn = video;
  bool frontCamera = true;
  bool sharingScreen = false;
  late bool speaker = video;

  /// What the other side is sending, from their `media` signals.
  late bool remoteVideo = video;
  bool remoteScreen = false;

  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();

  RTCPeerConnection? _pc;
  MediaStream? _local; // microphone
  MediaStream? _camera;
  MediaStream? _screen;

  /// Every call carries a video slot, so camera and screen can be switched on
  /// mid-call by swapping its track instead of renegotiating.
  RTCRtpSender? _videoSender;
  bool _remoteSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];
  Timer? _ringTimeout;
  Timer? _reoffer;

  CallService get _svc => CallService.instance;

  bool get canShareVideo => _videoSender != null;

  void _set(CallState s) {
    if (state == CallState.ended) return;
    state = s;
    notifyListeners();
  }

  Future<void> _setup() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _local = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    if (video) {
      _camera = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {'facingMode': 'user'},
      });
      localRenderer.srcObject = _camera;
    }

    final pc = await createPeerConnection({'iceServers': iceServers, 'sdpSemantics': 'unified-plan'});
    _pc = pc;
    for (final t in _local!.getAudioTracks()) {
      await pc.addTrack(t, _local!);
    }
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _svc.send(peer.id, {'type': 'candidate', 'callId': callId, 'candidate': c.toMap()});
    };
    pc.onTrack = (e) async {
      if (e.track.kind != 'video') return; // remote audio plays on its own
      final stream = e.streams.isNotEmpty ? e.streams.first : await createLocalMediaStream('remote');
      if (e.streams.isEmpty) await stream.addTrack(e.track);
      remoteRenderer.srcObject = stream;
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

  MediaStreamTrack? get _cameraTrack => _camera?.getVideoTracks().firstOrNull;

  Future<void> startOutgoing() async {
    try {
      await _setup();
      final t = await _pc!.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv, streams: [_local!]),
      );
      if (_cameraTrack != null) await t.sender.replaceTrack(_cameraTrack);
      _videoSender = t.sender;
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      final me = await Api.profile(myId);
      final payload = {
        'type': 'offer',
        'callId': callId,
        'sdp': offer.sdp,
        'video': video,
        'fromName': me?.displayName,
        'fromAvatar': me?.avatarUrl,
      };
      await _svc.send(peer.id, payload);
      Push.notify({'type': 'call', 'to': peer.id, 'call_id': callId, 'video': video});
      // Re-send for a callee who opens the app from the notification. By now the
      // local description carries the gathered ICE candidates they missed.
      _reoffer = Timer.periodic(const Duration(seconds: 3), (_) async {
        if (state != CallState.ringing) return _reoffer?.cancel();
        final desc = await _pc?.getLocalDescription();
        _svc.send(peer.id, {...payload, 'sdp': desc?.sdp ?? offer.sdp}).catchError((_) {});
      });
      _ringTimeout = Timer(const Duration(seconds: 45), () => hangup(reason: 'noAnswer'));
    } catch (_) {
      _end('error');
    }
  }

  Future<void> accept() async {
    _set(CallState.connecting);
    Push.cancelCall();
    try {
      await _setup();
      await _pc!.setRemoteDescription(RTCSessionDescription(remoteOffer, 'offer'));
      for (final t in await _pc!.getTransceivers()) {
        if (t.receiver.track?.kind != 'video') continue;
        await t.setDirection(TransceiverDirection.SendRecv);
        if (_cameraTrack != null) await t.sender.replaceTrack(_cameraTrack);
        _videoSender = t.sender;
        break;
      }
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
    if (outgoing && state == CallState.ringing) {
      Push.notify({'type': 'call_end', 'to': peer.id, 'call_id': callId});
    }
    _end(reason);
  }

  Future<void> handleSignal(Map<String, dynamic> d) async {
    switch (d['type']) {
      case 'answer':
        _ringTimeout?.cancel();
        _reoffer?.cancel();
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
      case 'media':
        remoteVideo = d['video'] == true;
        remoteScreen = d['screen'] == true;
        notifyListeners();
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

  void _sendMedia() {
    _svc.send(peer.id, {
      'type': 'media',
      'callId': callId,
      'video': cameraOn || sharingScreen,
      'screen': sharingScreen,
    }).catchError((_) {});
  }

  void toggleMute() {
    muted = !muted;
    for (final t in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  Future<void> _stopStream(MediaStream? s) async {
    for (final t in s?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    await s?.dispose();
  }

  Future<void> toggleCamera() async {
    if (_videoSender == null) return;
    if (cameraOn) {
      cameraOn = false;
      await _videoSender!.replaceTrack(null);
      await _stopStream(_camera);
      _camera = null;
      localRenderer.srcObject = null;
    } else {
      if (sharingScreen) await _stopScreen(notify: false);
      _camera = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {'facingMode': frontCamera ? 'user' : 'environment'},
      });
      await _videoSender!.replaceTrack(_cameraTrack);
      localRenderer.srcObject = _camera;
      cameraOn = true;
      if (!speaker) await toggleSpeaker();
    }
    _sendMedia();
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final track = _cameraTrack;
    if (track == null) return;
    frontCamera = await Helper.switchCamera(track);
    notifyListeners();
  }

  Future<void> toggleScreenShare() async {
    if (_videoSender == null) return;
    if (sharingScreen) return _stopScreen();
    if (Platform.isAndroid) {
      if (!await Helper.requestCapturePermission()) return;
      await _screenService.invokeMethod('start');
      // The service must be in the foreground before capture begins.
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    try {
      final screen = await navigator.mediaDevices.getDisplayMedia({'audio': false, 'video': true});
      final track = screen.getVideoTracks().first;
      track.onEnded = () => _stopScreen();
      if (cameraOn) {
        cameraOn = false;
        await _stopStream(_camera);
        _camera = null;
        localRenderer.srcObject = null;
      }
      _screen = screen;
      await _videoSender!.replaceTrack(track);
      sharingScreen = true;
      _sendMedia();
      notifyListeners();
    } catch (_) {
      if (Platform.isAndroid) await _screenService.invokeMethod('stop');
    }
  }

  Future<void> _stopScreen({bool notify = true}) async {
    if (!sharingScreen) return;
    sharingScreen = false;
    await _videoSender?.replaceTrack(null);
    await _stopStream(_screen);
    _screen = null;
    if (Platform.isAndroid) await _screenService.invokeMethod('stop');
    if (notify) {
      _sendMedia();
      notifyListeners();
    }
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    await Helper.setSpeakerphoneOn(speaker);
    notifyListeners();
  }

  void _end(String reason) {
    if (state == CallState.ended) return;
    _ringTimeout?.cancel();
    _reoffer?.cancel();
    endReason = reason;
    state = CallState.ended;
    notifyListeners();
    if (_svc.active == this) _svc.active = null;
    Push.cancelCall();

    _stopScreen(notify: false);
    for (final s in [_local, _camera]) {
      _stopStream(s);
    }
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

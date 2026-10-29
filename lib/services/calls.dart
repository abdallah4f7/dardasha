import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../models.dart';
import '../pages/call_page.dart';
import '../widgets/call_bubble.dart';
import 'api.dart';
import 'push.dart';

/// Most people in one call, the caller included. Everyone connects to everyone
/// else directly, so each extra person costs every phone another stream.
const maxCallSize = 6;

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
    final from = data['from'] as String?;
    if (callId == null || from == null) return;
    final s = active;

    // Someone already in this call connecting to us: no ringing.
    if (data['type'] == 'offer' && data['mesh'] == true) {
      if (s?.callId == callId) s!._onMeshOffer(from, data);
      return;
    }
    if (data['type'] == 'offer') {
      if (!_seenCalls.add(callId)) return;
      if (s != null) {
        send(from, {'type': 'busy', 'callId': callId});
        return;
      }
      _ring(callId, from, data);
      return;
    }
    if (s?.callId == callId) s!._handleSignal(from, data);
  }

  void _ring(String callId, String from, Map<String, dynamic> data) {
    final inviter = Profile(
      id: from,
      username: '',
      displayName: data['fromName'] as String? ?? '',
      avatarUrl: data['fromAvatar'] as String?,
    );
    final roster = [
      for (final r in (data['roster'] as List? ?? const []))
        if (r is Map && r['id'] != myId && r['id'] != from)
          Profile(id: r['id'] as String, username: '', displayName: r['name'] as String? ?? '', avatarUrl: r['avatar'] as String?),
    ];
    final s = CallSession(
      callId: callId,
      video: data['video'] == true,
      outgoing: false,
      conversationId: data['conv'] as String?,
      groupName: data['group'] as String?,
      // Older versions don't say: then it is a plain call between the two of us.
      core: {...?(data['core'] as List?)?.cast<String>(), if (data['core'] == null) ...[from, myId]},
    )
      .._inviter = inviter
      .._roster = roster;
    s._peerFor(inviter)._offer = data['sdp'] as String?;
    active = s;
    navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => CallPage(session: s)));
    if (_answerCallId == callId) {
      _answerCallId = null;
      s.accept();
    }
  }

  String? _answerCallId;

  /// "Answer" on the call notification: accept the call now, or as soon as its offer arrives.
  void answerWhenReady(String callId) {
    final s = active;
    if (s == null || s.callId != callId) {
      _answerCallId = callId;
    } else if (!s.outgoing && s.state == CallState.ringing) {
      s.accept();
    }
  }

  OverlayEntry? _bubble;

  /// Back from the call screen: the call goes on in a small floating bubble.
  void minimize(CallSession s) {
    _bubble?.remove();
    _bubble = OverlayEntry(
      builder: (_) => CallBubble(
        session: s,
        onOpen: () {
          _removeBubble();
          navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => CallPage(session: s)));
        },
        onGone: () {
          _removeBubble();
          s.disposeRenderers();
        },
      ),
    );
    navigatorKey.currentState?.overlay?.insert(_bubble!);
  }

  void _removeBubble() {
    _bubble?.remove();
    _bubble = null;
  }

  /// Calls one person and opens the call screen.
  Future<void> call(BuildContext context, Profile peer, {required bool video, String? conversationId}) =>
      _start(context, [peer], video: video, conversationId: conversationId, core: {myId, peer.id});

  /// Rings everyone in a group; its members can remove anyone added from outside it.
  Future<void> callGroup(
    BuildContext context,
    List<Profile> members, {
    required bool video,
    required String conversationId,
    required String groupName,
  }) {
    final others = members.where((m) => m.id != myId).take(maxCallSize - 1).toList();
    return _start(
      context,
      others,
      video: video,
      conversationId: conversationId,
      groupName: groupName,
      core: {myId, ...members.map((m) => m.id)},
    );
  }

  Future<void> _start(
    BuildContext context,
    List<Profile> invitees, {
    required bool video,
    required Set<String> core,
    String? conversationId,
    String? groupName,
  }) async {
    if (active != null || invitees.isEmpty) return;
    final s = CallSession(
      callId: const Uuid().v4(),
      video: video,
      outgoing: true,
      conversationId: conversationId,
      groupName: groupName,
      core: core,
    ).._pendingInvites = invitees;
    active = s;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CallPage(session: s)));
  }
}

enum CallState { ringing, connecting, connected, ended }

enum PeerState { ringing, connecting, connected }

/// Keeps Android's screen capture alive (it needs a foreground service).
const _screenService = MethodChannel('dardasha/screen');

bool get _isAndroid => !kIsWeb && Platform.isAndroid;

/// One other person in the call and our direct connection to them.
class CallPeer {
  CallPeer(this.profile);

  Profile profile;
  PeerState state = PeerState.ringing;

  /// What they are sending, from their `media` signals.
  bool remoteVideo = false;
  bool remoteScreen = false;

  final renderer = RTCVideoRenderer();

  /// Browsers only play remote audio through an element; phones play it by themselves.
  final _audio = RTCVideoRenderer();

  RTCPeerConnection? _pc;
  RTCRtpSender? _videoSender;
  bool _remoteSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];
  String? _offer; // their offer, until we answer it
  Timer? _ringTimeout;
  Timer? _reoffer;

  String get id => profile.id;

  Future<void> _close() async {
    _ringTimeout?.cancel();
    _reoffer?.cancel();
    await _pc?.close();
    _pc = null;
    for (final r in [renderer, if (kIsWeb) _audio]) {
      try {
        if (r.textureId != null) r.srcObject = null;
        await r.dispose();
      } catch (_) {}
    }
  }
}

class CallSession extends ChangeNotifier {
  CallSession({
    required this.callId,
    required this.video,
    required this.outgoing,
    required this.core,
    this.conversationId,
    this.groupName,
  });

  final String callId;
  final bool video;

  /// Whether we started the call (and post the call message when it ends).
  final bool outgoing;
  final String? conversationId;
  final String? groupName;

  /// Can't be removed, and may remove anyone else: the two in a private call,
  /// or the group's members in a group call.
  final Set<String> core;

  CallState state = CallState.ringing;
  String? endReason; // l10n key
  DateTime? connectedAt;

  bool muted = false;
  late bool cameraOn = video;
  bool frontCamera = true;
  bool sharingScreen = false;
  late bool speaker = video;

  final localRenderer = RTCVideoRenderer();

  /// Everyone else in the call (or being rung), by user id, in the order they came.
  final Map<String, CallPeer> peers = {};

  /// Who rang us, and who they said was in the call then.
  Profile? _inviter;
  List<Profile> _roster = [];
  List<Profile> _pendingInvites = [];

  MediaStream? _local; // microphone
  MediaStream? _camera;
  MediaStream? _screen;
  Future<void>? _setupDone;
  bool _started = false;

  CallService get _svc => CallService.instance;

  bool get isGroup => groupName != null;

  /// The person the screen is about: who rang us, or the first one in the call.
  Profile get peer =>
      (state == CallState.ringing && !outgoing ? _inviter : null) ??
      peers.values.where((p) => p.state == PeerState.connected).firstOrNull?.profile ??
      peers.values.firstOrNull?.profile ??
      _inviter ??
      Profile(id: '', username: '', displayName: '');

  CallPeer? get _main => peers[peer.id];
  bool get remoteVideo => _main?.remoteVideo ?? false;
  bool get remoteScreen => _main?.remoteScreen ?? false;
  RTCVideoRenderer get remoteRenderer => _main?.renderer ?? localRenderer;

  bool get canShareVideo => _local != null;
  bool get canInvite => state == CallState.connected && peers.length + 1 < maxCallSize;

  /// Only the group's members (or the two in a private call) remove people, and
  /// only people added from outside.
  bool canRemove(String userId) => core.contains(myId) && !core.contains(userId);

  void _set(CallState s) {
    if (state == CallState.ended) return;
    state = s;
    notifyListeners();
  }

  // ───── Media ─────

  Future<void> _setup() => _setupDone ??= () async {
    await localRenderer.initialize();
    _local = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    if (video) {
      _camera = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {'facingMode': 'user'},
      });
      localRenderer.srcObject = _camera;
    }
    await _applySpeaker();
    notifyListeners();
  }();

  Future<void> _applySpeaker() async {
    if (kIsWeb) return; // the browser picks the output
    await Helper.setSpeakerphoneOn(speaker);
  }

  MediaStreamTrack? get _cameraTrack => _camera?.getVideoTracks().firstOrNull;

  /// What our video slot carries right now: the shared screen, the camera, or nothing.
  MediaStreamTrack? get _videoTrack => _screen?.getVideoTracks().firstOrNull ?? _cameraTrack;

  // ───── Connections ─────

  CallPeer _peerFor(Profile p) => peers.putIfAbsent(p.id, () => CallPeer(p));

  /// Every connection carries a video slot, so camera and screen can be switched
  /// on mid-call by swapping its track instead of renegotiating.
  Future<RTCPeerConnection> _connect(CallPeer p, {required bool offering}) async {
    await _setup();
    final pc = await createPeerConnection({'iceServers': iceServers, 'sdpSemantics': 'unified-plan'});
    p._pc = pc;
    await p.renderer.initialize();
    if (kIsWeb) await p._audio.initialize();
    for (final t in _local!.getAudioTracks()) {
      await pc.addTrack(t, _local!);
    }
    if (offering) {
      final t = await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv, streams: [_local!]),
      );
      if (_videoTrack != null) await t.sender.replaceTrack(_videoTrack);
      p._videoSender = t.sender;
    }
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _svc.send(p.id, {'type': 'candidate', 'callId': callId, 'candidate': c.toMap()}).catchError((_) {});
    };
    pc.onTrack = (e) async {
      if (e.track.kind != 'video') {
        if (kIsWeb && e.streams.isNotEmpty) p._audio.srcObject = e.streams.first;
        return;
      }
      final stream = e.streams.isNotEmpty ? e.streams.first : await createLocalMediaStream('remote');
      if (e.streams.isEmpty) await stream.addTrack(e.track);
      p.renderer.srcObject = stream;
      notifyListeners();
    };
    pc.onConnectionState = (st) {
      if (st == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        p.state = PeerState.connected;
        connectedAt ??= DateTime.now();
        _set(CallState.connected);
      } else if (st == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _drop(p.id, reason: 'callEnded');
      }
      notifyListeners();
    };
    return pc;
  }

  /// Answers an offer on [p]'s connection.
  Future<void> _answer(CallPeer p, String? sdp) async {
    final pc = p._pc ?? await _connect(p, offering: false);
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    for (final t in await pc.getTransceivers()) {
      if (t.receiver.track?.kind != 'video') continue;
      await t.setDirection(TransceiverDirection.SendRecv);
      if (_videoTrack != null) await t.sender.replaceTrack(_videoTrack);
      p._videoSender = t.sender;
      break;
    }
    await _flushCandidates(p);
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    p.state = PeerState.connecting;
    await _svc.send(p.id, {'type': 'answer', 'callId': callId, 'sdp': answer.sdp});
    _sendMediaTo(p);
  }

  Future<void> _flushCandidates(CallPeer p) async {
    p._remoteSet = true;
    for (final c in p._pendingCandidates) {
      await p._pc!.addCandidate(c);
    }
    p._pendingCandidates.clear();
  }

  List<Map<String, dynamic>> _rosterFor(String exclude) => [
    for (final p in peers.values)
      if (p.id != exclude) {'id': p.id, 'name': p.profile.displayName, 'avatar': p.profile.avatarUrl},
  ];

  // ───── Ringing people ─────

  /// Safe to call again when the call screen is reopened from the bubble.
  Future<void> startOutgoing() async {
    if (_started) return;
    _started = true;
    try {
      await _setup();
      final people = _pendingInvites;
      _pendingInvites = [];
      await Future.wait(people.map(invite));
    } catch (_) {
      _end('error');
    }
  }

  /// Rings someone into the call: at the start, or added from inside it.
  Future<void> invite(Profile who) async {
    if (state == CallState.ended || peers.containsKey(who.id) || peers.length + 1 >= maxCallSize) return;
    final p = _peerFor(who);
    notifyListeners();
    try {
      final pc = await _connect(p, offering: true);
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      final me = await Api.profile(myId);
      final payload = {
        'type': 'offer',
        'callId': callId,
        'sdp': offer.sdp,
        'video': video,
        'fromName': me?.displayName,
        'fromAvatar': me?.avatarUrl,
        'core': core.toList(),
        'conv': ?conversationId,
        'group': ?groupName,
        'roster': _rosterFor(who.id),
      };
      await _svc.send(who.id, payload);
      Push.notify({'type': 'call', 'to': who.id, 'call_id': callId, 'video': video});
      // Re-send for someone who opens the app from the notification. By now the
      // local description carries the gathered ICE candidates they missed.
      p._reoffer = Timer.periodic(const Duration(seconds: 3), (_) async {
        if (p.state != PeerState.ringing) return p._reoffer?.cancel();
        final desc = await p._pc?.getLocalDescription();
        _svc.send(who.id, {...payload, 'sdp': desc?.sdp ?? offer.sdp}).catchError((_) {});
      });
      p._ringTimeout = Timer(const Duration(seconds: 45), () {
        if (p.state != PeerState.ringing) return;
        Push.notify({'type': 'call_end', 'to': who.id, 'call_id': callId});
        _svc.send(who.id, {'type': 'end', 'callId': callId}).catchError((_) {});
        _drop(who.id, reason: 'noAnswer');
      });
    } catch (_) {
      _drop(who.id, reason: 'error');
    }
  }

  Future<void> accept() async {
    final inviter = _inviter;
    final p = inviter == null ? null : peers[inviter.id];
    if (p == null) return;
    _set(CallState.connecting);
    Push.cancelCall();
    try {
      await _answer(p, p._offer);
      // Tell everyone else in the call we're here; each of them connects to us.
      for (final other in _roster) {
        _svc.send(other.id, {
          'type': 'joined',
          'callId': callId,
          'name': (await Api.profile(myId))?.displayName,
        }).catchError((_) {});
      }
    } catch (_) {
      hangup(reason: 'error');
    }
  }

  void decline() {
    final inviter = _inviter;
    if (inviter != null) _svc.send(inviter.id, {'type': 'reject', 'callId': callId}).catchError((_) {});
    _end('declined');
  }

  void hangup({String reason = 'callEnded'}) {
    if (state == CallState.ended) return;
    for (final p in peers.values) {
      _svc.send(p.id, {'type': 'end', 'callId': callId}).catchError((_) {});
      if (p.state == PeerState.ringing && outgoing) {
        Push.notify({'type': 'call_end', 'to': p.id, 'call_id': callId});
      }
    }
    _end(reason);
  }

  /// Removes someone added from outside the group (or the private call).
  void remove(String userId) {
    if (!canRemove(userId) || !peers.containsKey(userId)) return;
    for (final p in peers.values) {
      _svc.send(p.id, {'type': 'kick', 'callId': callId, 'target': userId}).catchError((_) {});
    }
    _drop(userId, reason: 'callEnded');
  }

  /// [userId] left (or was removed, or never answered). The call ends with the last of them.
  void _drop(String userId, {required String reason}) {
    final p = peers.remove(userId);
    if (p == null) return;
    p._close();
    if (peers.isEmpty) {
      _end(reason);
    } else {
      notifyListeners();
    }
  }

  // ───── Signals ─────

  /// Someone in the call connects to us. Both sides may offer at once when two
  /// people join together; the one with the smaller id keeps its own offer.
  Future<void> _onMeshOffer(String from, Map<String, dynamic> d) async {
    if (state == CallState.ended || state == CallState.ringing) return;
    final existing = peers[from];
    if (existing?._pc != null) {
      final ours = await existing!._pc!.getSignalingState();
      if (ours == RTCSignalingState.RTCSignalingStateHaveLocalOffer && myId.compareTo(from) < 0) return;
      await existing._close();
      peers.remove(from);
    }
    final p = _peerFor(
      Profile(id: from, username: '', displayName: d['fromName'] as String? ?? '', avatarUrl: d['fromAvatar'] as String?),
    );
    try {
      await _answer(p, d['sdp'] as String?);
    } catch (_) {
      _drop(from, reason: 'error');
    }
  }

  /// Offers a connection to someone already in the call.
  Future<void> _meshOffer(Profile who) async {
    if (peers[who.id]?._pc != null) return;
    final p = _peerFor(who)..state = PeerState.connecting;
    notifyListeners();
    try {
      final pc = await _connect(p, offering: true);
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      final me = await Api.profile(myId);
      await _svc.send(who.id, {
        'type': 'offer',
        'mesh': true,
        'callId': callId,
        'sdp': offer.sdp,
        'video': video,
        'fromName': me?.displayName,
        'fromAvatar': me?.avatarUrl,
      });
    } catch (_) {
      _drop(who.id, reason: 'error');
    }
  }

  Future<void> _handleSignal(String from, Map<String, dynamic> d) async {
    final p = peers[from];
    switch (d['type']) {
      case 'answer':
        if (p?._pc == null) return;
        p!._ringTimeout?.cancel();
        p._reoffer?.cancel();
        p.state = PeerState.connecting;
        if (state == CallState.ringing) _set(CallState.connecting);
        await p._pc!.setRemoteDescription(RTCSessionDescription(d['sdp'] as String?, 'answer'));
        await _flushCandidates(p);
        _sendMediaTo(p);
        // In case anyone joined after we rang them.
        _svc.send(from, {'type': 'peers', 'callId': callId, 'list': _rosterFor(from)}).catchError((_) {});
        notifyListeners();
      case 'candidate':
        if (p == null) return;
        final c = Map<String, dynamic>.from(d['candidate'] as Map);
        final cand = RTCIceCandidate(c['candidate'] as String?, c['sdpMid'] as String?, c['sdpMLineIndex'] as int?);
        if (p._pc != null && p._remoteSet) {
          await p._pc!.addCandidate(cand);
        } else {
          p._pendingCandidates.add(cand);
        }
      case 'media':
        if (p == null) return;
        p.remoteVideo = d['video'] == true;
        p.remoteScreen = d['screen'] == true;
        notifyListeners();
      case 'joined':
        if (state == CallState.ringing) return; // we'll announce ourselves when we answer
        await _meshOffer(Profile(id: from, username: '', displayName: d['name'] as String? ?? ''));
        _svc.send(from, {'type': 'peers', 'callId': callId, 'list': _rosterFor(from)}).catchError((_) {});
      case 'peers':
        // Anyone they're with that we haven't met: say hello, and they connect to us.
        for (final r in (d['list'] as List? ?? const [])) {
          if (r is! Map) continue;
          final id = r['id'] as String?;
          if (id == null || id == myId || peers.containsKey(id)) continue;
          _svc.send(id, {'type': 'joined', 'callId': callId, 'name': (await Api.profile(myId))?.displayName})
              .catchError((_) {});
        }
      case 'kick':
        final target = d['target'] as String?;
        if (target == null || !core.contains(from) || core.contains(target)) return;
        if (target == myId) {
          for (final other in peers.values) {
            _svc.send(other.id, {'type': 'end', 'callId': callId}).catchError((_) {});
          }
          _end('removedFromCall');
        } else {
          _drop(target, reason: 'callEnded');
        }
      case 'reject':
        _drop(from, reason: 'declined');
      case 'busy':
        _drop(from, reason: 'busy');
      case 'end':
        if (state == CallState.ringing && !outgoing && from == _inviter?.id) {
          _end('callEnded'); // they stopped ringing us
        } else {
          _drop(from, reason: 'callEnded');
        }
    }
  }

  void _sendMediaTo(CallPeer p) {
    _svc.send(p.id, {
      'type': 'media',
      'callId': callId,
      'video': cameraOn || sharingScreen,
      'screen': sharingScreen,
    }).catchError((_) {});
  }

  void _sendMedia() {
    for (final p in peers.values) {
      if (p._pc != null) _sendMediaTo(p);
    }
  }

  Future<void> _setVideoTrack(MediaStreamTrack? track) async {
    for (final p in peers.values) {
      await p._videoSender?.replaceTrack(track);
    }
  }

  // ───── Controls ─────

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
    if (!canShareVideo) return;
    if (cameraOn) {
      cameraOn = false;
      await _setVideoTrack(null);
      await _stopStream(_camera);
      _camera = null;
      localRenderer.srcObject = null;
    } else {
      if (sharingScreen) await _stopScreen(notify: false);
      _camera = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {'facingMode': frontCamera ? 'user' : 'environment'},
      });
      await _setVideoTrack(_cameraTrack);
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
    try {
      frontCamera = await Helper.switchCamera(track);
    } catch (_) {} // some browsers have one camera or no switching
    notifyListeners();
  }

  Future<void> toggleScreenShare() async {
    if (!canShareVideo) return;
    if (sharingScreen) return _stopScreen();
    if (_isAndroid) {
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
      await _setVideoTrack(track);
      sharingScreen = true;
      _sendMedia();
      notifyListeners();
    } catch (_) {
      if (_isAndroid) await _screenService.invokeMethod('stop');
    }
  }

  Future<void> _stopScreen({bool notify = true}) async {
    if (!sharingScreen) return;
    sharingScreen = false;
    await _setVideoTrack(null);
    await _stopStream(_screen);
    _screen = null;
    if (_isAndroid) await _screenService.invokeMethod('stop');
    if (notify) {
      _sendMedia();
      notifyListeners();
    }
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    await _applySpeaker();
    notifyListeners();
  }

  void _end(String reason) {
    if (state == CallState.ended) return;
    endReason = reason;
    state = CallState.ended;
    notifyListeners();
    if (_svc.active == this) _svc.active = null;
    Push.cancelCall();

    _stopScreen(notify: false);
    for (final s in [_local, _camera]) {
      _stopStream(s);
    }
    for (final p in peers.values) {
      p._ringTimeout?.cancel();
      p._reoffer?.cancel();
      p._pc?.close();
    }

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
    for (final p in peers.values) {
      await p._close();
    }
    try {
      localRenderer.srcObject = null;
      await localRenderer.dispose();
    } catch (_) {}
  }
}

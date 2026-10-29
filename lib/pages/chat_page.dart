import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import '../services/calls.dart';
import '../services/push.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';
import '../widgets/message_bubble.dart';
import '../widgets/sticker_panel.dart';
import 'group_info_page.dart';
import 'user_page.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.conversationId,
    required this.isGroup,
    required this.title,
    this.avatarUrl,
    this.peer,
  });

  final String conversationId;
  final bool isGroup;
  final String title;
  final String? avatarUrl;
  final Profile? peer;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late final Stream<List<Message>> _messages = db
      .from('messages')
      .stream(primaryKey: ['id'])
      .eq('conversation_id', widget.conversationId)
      .order('created_at', ascending: false)
      .limit(300)
      .map((rows) => rows.map(Message.fromMap).toList());

  late final Stream<Map<String, List<Reaction>>> _reactions = db
      .from('reactions')
      .stream(primaryKey: ['message_id', 'user_id'])
      .eq('conversation_id', widget.conversationId)
      .map((rows) {
        final map = <String, List<Reaction>>{};
        for (final r in rows.map(Reaction.fromMap)) {
          (map[r.messageId] ??= []).add(r);
        }
        return map;
      });

  Message? _replyTo;
  Message? _editing;

  // Shown right away, before the stream catches up. Deletes never reach a
  // filtered stream, so they also come from [_deletes].
  final Set<String> _deleted = {};
  final Map<String, Message> _edited = {};
  RealtimeChannel? _deletes;

  final _text = TextEditingController();
  final _focus = FocusNode();
  final _picker = ImagePicker();
  final _recorder = AudioRecorder();
  Map<String, Profile> _members = {};
  Profile? _peer;
  int _uploads = 0;

  bool _recording = false;
  bool _cancelRecording = false;

  /// Slid up onto the lock: recording goes on hands-free, with send / pause / delete buttons.
  bool _locked = false;
  bool _paused = false;
  DateTime? _recStart; // start of the current (unpaused) stretch
  Duration _recBefore = Duration.zero; // recorded before the last pause
  Timer? _recTicker;

  /// Phones stream AAC frames that can be joined back to back, so a paused
  /// recording can be played as it stands and then continued.
  final _recBytes = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _recSub;
  AudioPlayer? _preview;

  Duration get _recElapsed =>
      _recBefore + (_paused || _recStart == null ? Duration.zero : DateTime.now().difference(_recStart!));

  @override
  void initState() {
    super.initState();
    _peer = widget.peer;
    Push.openConversation = widget.conversationId;
    Push.clearConversation(widget.conversationId);
    _deletes = db
        .channel('deletes:${widget.conversationId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'messages',
          callback: (p) {
            final id = p.oldRecord['id'];
            if (id is String && mounted) setState(() => _deleted.add(id));
          },
        )
        .subscribe();
    _text.addListener(() => setState(() {}));
    Api.members(widget.conversationId).then((list) {
      if (!mounted) return;
      setState(() {
        _members = {for (final p in list) p.id: p};
        if (!widget.isGroup) _peer ??= list.where((p) => p.id != myId).firstOrNull;
      });
    });
  }

  @override
  void dispose() {
    if (Push.openConversation == widget.conversationId) Push.openConversation = null;
    if (_deletes != null) db.removeChannel(_deletes!);
    _recTicker?.cancel();
    _recSub?.cancel();
    _preview?.dispose();
    _recorder.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startEdit(Message m) {
    setState(() {
      _replyTo = null;
      _editing = m;
    });
    _text.text = m.content ?? '';
    _focus.requestFocus();
  }

  void _cancelEdit() {
    setState(() => _editing = null);
    _text.clear();
  }

  void _openProfile(Profile p) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => UserPage(user: p, fromConversationId: widget.isGroup ? null : widget.conversationId),
    ),
  );

  void _delete(Message m) {
    setState(() => _deleted.add(m.id));
    Api.deleteMessage(m.id).catchError((Object e) {
      if (!mounted) return;
      setState(() => _deleted.remove(m.id));
      showError(context, e);
    });
  }

  /// The stream's copy, unless a local edit is newer than what it has seen.
  Message _current(Message m) {
    final local = _edited[m.id];
    return local != null && m.content != local.content ? local : m;
  }

  /// Takes the pending reply (if any) as message meta and clears the banner.
  Map<String, dynamic> _takeReply() {
    final r = _replyTo;
    if (r == null) return {};
    setState(() => _replyTo = null);
    final text = r.content ?? '';
    return {
      'reply': {
        'id': r.id,
        'name': _members[r.senderId]?.displayName ?? '',
        'type': r.type,
        'text': r.type == 'text' ? text.substring(0, text.length.clamp(0, 120)) : null,
      },
    };
  }

  void _react(Message m, String emoji, List<Reaction> current) {
    final mine = current.where((r) => r.userId == myId).firstOrNull?.emoji;
    Api.react(m, emoji, current: mine).catchError((Object e) {
      if (mounted) showError(context, e);
    });
  }

  Future<void> _guard(Future<void> Function() action) async {
    setState(() => _uploads++);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploads--);
    }
  }

  void _sendText() {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _text.clear();
    final editing = _editing;
    if (editing != null) {
      setState(() => _editing = null);
      if (t == editing.content) return;
      setState(
        () => _edited[editing.id] = Message(
          id: editing.id,
          conversationId: editing.conversationId,
          senderId: editing.senderId,
          type: editing.type,
          content: t,
          mediaUrl: editing.mediaUrl,
          meta: {...editing.meta, 'edited': true}..remove('preview'),
          createdAt: editing.createdAt,
        ),
      );
      Api.editMessage(editing, t).catchError((Object e) {
        if (!mounted) return;
        setState(() => _edited.remove(editing.id));
        showError(context, e);
      });
      return;
    }
    Api.sendText(widget.conversationId, t, meta: _takeReply()).catchError((Object e) {
      if (mounted) showError(context, e);
    });
  }

  Future<void> _sendImage(XFile x, [Map<String, dynamic> reply = const {}]) => _guard(() async {
    final bytes = await x.readAsBytes();
    final img = await decodeImageFromList(bytes);
    final ext = x.name.contains('.') ? x.name.split('.').last.toLowerCase() : 'jpg';
    final url = await Api.upload(bytes, ext, contentTypeFor(x.name));
    await Api.send(
      widget.conversationId,
      type: 'image',
      mediaUrl: url,
      meta: {...reply, 'w': img.width, 'h': img.height},
    );
  });

  Future<void> _sendVideo(XFile x, [Map<String, dynamic> reply = const {}]) => _guard(() async {
    final bytes = await x.readAsBytes();
    final ext = x.name.contains('.') ? x.name.split('.').last.toLowerCase() : 'mp4';
    final url = await Api.upload(bytes, ext, contentTypeFor(x.name));
    await Api.send(widget.conversationId, type: 'video', mediaUrl: url, meta: reply);
  });

  Future<void> _sendFile(PlatformFile f, [Map<String, dynamic> reply = const {}]) => _guard(() async {
    final bytes = await f.readAsBytes();
    final ext = f.extension?.toLowerCase() ?? 'bin';
    final url = await Api.upload(bytes, ext, contentTypeFor(f.name));
    await Api.send(
      widget.conversationId,
      type: 'file',
      content: f.name,
      mediaUrl: url,
      meta: {...reply, 'size': bytes.length},
    );
  });

  void _sendSticker(StickerChoice s) {
    Api.send(widget.conversationId, type: 'sticker', mediaUrl: s.url, content: s.emoji, meta: _takeReply()).catchError((
      Object e,
    ) {
      if (mounted) showError(context, e);
      return <String, dynamic>{};
    });
  }

  Future<void> _attach() async {
    final l = L.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(l.t('photo')),
              onTap: () => Navigator.pop(c, 'photos'),
            ),
            ListTile(
              leading: const Icon(Icons.video_library),
              title: Text(l.t('video')),
              onTap: () => Navigator.pop(c, 'video'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: Text(l.t('camera')),
              onTap: () => Navigator.pop(c, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: Text(l.t('recordVideo')),
              onTap: () => Navigator.pop(c, 'recordVideo'),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(l.t('file')),
              onTap: () => Navigator.pop(c, 'file'),
            ),
          ],
        ),
      ),
    );
    switch (choice) {
      case 'photos':
        final xs = await _picker.pickMultiImage(imageQuality: 80, maxWidth: 1920, maxHeight: 1920);
        if (xs.isEmpty) return;
        final reply = _takeReply();
        for (final (i, x) in xs.indexed) {
          await _sendImage(x, i == 0 ? reply : const {});
        }
      case 'camera':
        final x = await _picker.pickImage(source: ImageSource.camera, imageQuality: 80, maxWidth: 1920);
        if (x != null) await _sendImage(x, _takeReply());
      case 'video':
        final x = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(minutes: 5));
        if (x != null) await _sendVideo(x, _takeReply());
      case 'recordVideo':
        final x = await _picker.pickVideo(source: ImageSource.camera, maxDuration: const Duration(minutes: 3));
        if (x != null) await _sendVideo(x, _takeReply());
      case 'file':
        final files = await FilePicker.pickFiles();
        if (files.isEmpty) return;
        final reply = _takeReply();
        for (final (i, f) in files.indexed) {
          await _sendFile(f, i == 0 ? reply : const {});
        }
    }
  }

  /// Phones record AAC. Browsers record what they can: Safari AAC, Chrome Opus/WebM.
  bool _recordingAac = true;

  Future<void> _startRecording() async {
    if (!await _recorder.hasPermission()) {
      if (mounted) toast(context, L.of(context).t('micDenied'));
      return;
    }
    _recBytes.clear();
    if (kIsWeb) {
      _recordingAac = await _recorder.isEncoderSupported(AudioEncoder.aacLc);
      final encoder = _recordingAac ? AudioEncoder.aacLc : AudioEncoder.opus;
      await _recorder.start(RecordConfig(encoder: encoder, bitRate: 64000), path: '');
    } else {
      final stream = await _recorder.startStream(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, numChannels: 1),
      );
      _recSub = stream.listen(_recBytes.add);
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _recording = true;
      _cancelRecording = false;
      _locked = false;
      _paused = false;
      _recBefore = Duration.zero;
      _recStart = DateTime.now();
    });
    _recTicker = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
  }

  /// Ends the recording and returns its audio (null when there is none).
  Future<Uint8List?> _finishRecording() async {
    _recTicker?.cancel();
    await _preview?.stop();
    final path = await _recorder.stop();
    if (kIsWeb) return path == null ? null : await XFile(path).readAsBytes();
    await _recSub?.asFuture<void>().timeout(const Duration(seconds: 2), onTimeout: () {});
    _recSub = null;
    return _recBytes.takeBytes();
  }

  void _resetRecording() {
    _preview?.dispose();
    _preview = null;
    setState(() {
      _recording = false;
      _locked = false;
      _paused = false;
    });
  }

  /// Finger lifted (sends unless slid away to cancel), or the send button when locked.
  Future<void> _stopRecording() async {
    if (!_recording) return;
    final ms = _recElapsed.inMilliseconds;
    final cancel = _cancelRecording;
    final bytes = await _finishRecording();
    _resetRecording();
    if (cancel || bytes == null || bytes.isEmpty || ms < 700) return;
    final reply = _takeReply();
    await _guard(() async {
      final url = kIsWeb
          ? (_recordingAac
                ? await Api.upload(bytes, 'm4a', 'audio/mp4')
                : await Api.upload(bytes, 'webm', 'audio/webm'))
          : await Api.upload(bytes, 'aac', 'audio/aac');
      await Api.send(widget.conversationId, type: 'voice', mediaUrl: url, meta: {...reply, 'ms': ms});
    });
  }

  Future<void> _deleteRecording() async {
    await _finishRecording();
    _recBytes.clear();
    _resetRecording();
  }

  /// Pausing makes what was recorded so far playable; continuing stops the playback.
  Future<void> _togglePause() async {
    if (_paused) {
      await _preview?.pause();
      await _recorder.resume();
      setState(() {
        _paused = false;
        _recStart = DateTime.now();
      });
      return;
    }
    await _recorder.pause();
    setState(() {
      _recBefore = _recElapsed;
      _paused = true;
    });
    if (kIsWeb) return; // the browser only hands over the audio when recording stops
    final file = File('${(await getTemporaryDirectory()).path}/voice_preview.aac');
    await file.writeAsBytes(_recBytes.toBytes());
    final player = _preview ??= AudioPlayer();
    await player.setFilePath(file.path);
    if (mounted) setState(() {});
  }

  void _call(bool video) {
    if (widget.isGroup) {
      if (_members.length < 2) return;
      CallService.instance.callGroup(
        context,
        _members.values.toList(),
        video: video,
        conversationId: widget.conversationId,
        groupName: widget.title,
      );
      return;
    }
    final peer = _peer;
    if (peer == null) return;
    CallService.instance.call(context, peer, video: video, conversationId: widget.conversationId);
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: widget.isGroup
              ? () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => GroupInfoPage(conversationId: widget.conversationId, name: widget.title),
                  ),
                )
              : _peer == null
              ? null
              : () => _openProfile(_peer!),
          child: Row(
            children: [
              Avatar(
                name: widget.title,
                url: widget.avatarUrl ?? _peer?.avatarUrl,
                radius: 18,
                group: widget.isGroup && widget.avatarUrl == null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title.isEmpty ? (_peer?.displayName ?? '') : widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.isGroup && _members.isNotEmpty)
                      Text(
                        _members.values.map((m) => m.id == myId ? l.t('you') : m.displayName).join('، '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (!widget.isGroup) ...[
            IconButton(
              tooltip: l.t('videoCall'),
              icon: const Icon(Icons.videocam_outlined),
              onPressed: () => _call(true),
            ),
            IconButton(tooltip: l.t('voiceCall'), icon: const Icon(Icons.call_outlined), onPressed: () => _call(false)),
          ] else
            IconButton(
              icon: const Icon(Icons.info_outline),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GroupInfoPage(conversationId: widget.conversationId, name: widget.title),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Message>>(
              stream: _messages,
              builder: (context, snap) {
                if (snap.hasError) return Center(child: Text('${l.t('error')}\n${snap.error}'));
                final msgs = snap.data?.where((m) => !_deleted.contains(m.id)).map(_current).toList();
                if (msgs == null) return const Center(child: CircularProgressIndicator());
                return StreamBuilder<Map<String, List<Reaction>>>(
                  stream: _reactions,
                  builder: (context, rsnap) {
                    final reactions = rsnap.data ?? const {};
                    return ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      itemCount: msgs.length,
                      itemBuilder: (context, i) {
                        final m = msgs[i];
                        final older = i + 1 < msgs.length ? msgs[i + 1] : null;
                        final newDay = older == null || !DateUtils.isSameDay(older.createdAt, m.createdAt);
                        final sameSender = !newDay && older.senderId == m.senderId;
                        final mine = m.senderId == myId;
                        final sender = _members[m.senderId];
                        return Column(
                          children: [
                            if (newDay) _DateChip(date: m.createdAt),
                            MessageBubble(
                              key: ValueKey(m.id),
                              message: m,
                              mine: mine,
                              senderName: widget.isGroup && !mine && !sameSender ? sender?.displayName : null,
                              compact: sameSender,
                              reactions: reactions[m.id] ?? const [],
                              onReply: (m) => setState(() {
                                _replyTo = m;
                                if (_editing != null) _cancelEdit();
                              }),
                              onEdit: _startEdit,
                              onDelete: _delete,
                              onSenderTap: sender == null ? null : () => _openProfile(sender),
                              onReact: (e) => _react(m, e, reactions[m.id] ?? const []),
                            ),
                          ],
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
          if (_editing != null)
            _ReplyBanner(
              icon: Icons.edit_outlined,
              name: l.t('editMessage'),
              label: _editing!.content ?? '',
              onClose: _cancelEdit,
            )
          else if (_replyTo != null)
            _ReplyBanner(
              icon: Icons.reply,
              name: _replyTo!.senderId == myId ? l.t('you') : (_members[_replyTo!.senderId]?.displayName ?? ''),
              label: lastMessageLabel(l, _replyTo!.type, _replyTo!.content),
              onClose: () => setState(() => _replyTo = null),
            ),
          if (_uploads > 0) LinearProgressIndicator(minHeight: 2, backgroundColor: scheme.surfaceContainerHighest),
          SafeArea(
            top: false,
            child: _locked
                ? _LockedRecorder(
                    elapsed: _recElapsed,
                    paused: _paused,
                    preview: _preview,
                    onSend: _stopRecording,
                    onPause: _togglePause,
                    onDelete: _deleteRecording,
                  )
                : Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (!_recording)
                    IconButton(
                      tooltip: l.t('stickers'),
                      icon: const Icon(Icons.emoji_emotions_outlined),
                      onPressed: () => showStickerPanel(context, onPick: _sendSticker),
                    ),
                  Expanded(
                    child: _recording
                        ? _RecordingBar(elapsed: _recElapsed, cancelling: _cancelRecording)
                        : TextField(
                            controller: _text,
                            focusNode: _focus,
                            minLines: 1,
                            maxLines: 6,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(
                              hintText: l.t('typeMessage'),
                              isDense: true,
                              suffixIcon: _text.text.isEmpty
                                  ? IconButton(icon: const Icon(Icons.attach_file), onPressed: _attach)
                                  : null,
                            ),
                          ),
                  ),
                  const SizedBox(width: 6),
                  _text.text.trim().isNotEmpty
                      ? FloatingActionButton.small(
                          heroTag: null,
                          elevation: 0,
                          onPressed: _sendText,
                          child: Icon(_editing != null ? Icons.check_rounded : Icons.send_rounded),
                        )
                      : GestureDetector(
                          onTap: () => toast(context, l.t('holdToRecord')),
                          onLongPressStart: (_) => _startRecording(),
                          onLongPressMoveUpdate: (d) {
                            if (!_recording || _locked) return;
                            // Up onto the lock: keep recording without holding.
                            if (d.offsetFromOrigin.dy < -_lockDistance) {
                              HapticFeedback.mediumImpact();
                              setState(() {
                                _locked = true;
                                _cancelRecording = false;
                              });
                              return;
                            }
                            final cancel = d.offsetFromOrigin.dx.abs() > 90;
                            if (cancel != _cancelRecording) setState(() => _cancelRecording = cancel);
                          },
                          onLongPressEnd: (_) {
                            if (!_locked) _stopRecording();
                          },
                          child: Stack(
                            clipBehavior: Clip.none,
                            alignment: Alignment.bottomCenter,
                            children: [
                              if (_recording)
                                Positioned(
                                  bottom: 64,
                                  child: _LockHint(color: scheme.surfaceContainerHighest, fg: scheme.onSurfaceVariant),
                                ),
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                width: _recording ? 56 : 40,
                                height: _recording ? 56 : 40,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _recording ? scheme.error : scheme.primaryContainer,
                                ),
                                child: Icon(
                                  Icons.mic,
                                  color: _recording ? scheme.onError : scheme.onPrimaryContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const _lockDistance = 80.0;

/// Above the mic while it is held: slide up to here to lock the recording.
class _LockHint extends StatelessWidget {
  const _LockHint({required this.color, required this.fg});

  final Color color;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline, size: 20, color: fg),
          Icon(Icons.keyboard_arrow_up_rounded, size: 20, color: fg),
        ],
      ),
    );
  }
}

/// A locked recording: what was recorded (playable while paused) above
/// delete, pause / continue and send.
class _LockedRecorder extends StatelessWidget {
  const _LockedRecorder({
    required this.elapsed,
    required this.paused,
    required this.preview,
    required this.onSend,
    required this.onPause,
    required this.onDelete,
  });

  final Duration elapsed;
  final bool paused;
  final AudioPlayer? preview;
  final VoidCallback onSend;
  final VoidCallback onPause;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final scheme = Theme.of(context).colorScheme;
    final player = preview;
    const tabular = TextStyle(fontFeatures: [ui.FontFeature.tabularFigures()]);
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(24)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 48,
            child: paused && player != null
                ? StreamBuilder<PlayerState>(
                    stream: player.playerStateStream,
                    builder: (_, snap) {
                      final playing = snap.data?.playing == true &&
                          snap.data?.processingState != ProcessingState.completed;
                      return Row(
                        children: [
                          IconButton(
                            icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                            onPressed: () async {
                              if (playing) return player.pause();
                              if (player.processingState == ProcessingState.completed) {
                                await player.seek(Duration.zero);
                              }
                              await player.play();
                            },
                          ),
                          Expanded(
                            child: StreamBuilder<Duration>(
                              stream: player.positionStream,
                              builder: (_, pos) {
                                final total = player.duration ?? elapsed;
                                final at = pos.data ?? Duration.zero;
                                final max = total.inMilliseconds.toDouble().clamp(1, double.infinity).toDouble();
                                return Slider(
                                  max: max,
                                  value: at.inMilliseconds.toDouble().clamp(0, max),
                                  onChanged: (v) => player.seek(Duration(milliseconds: v.round())),
                                );
                              },
                            ),
                          ),
                          Text(formatDuration(elapsed), style: tabular),
                        ],
                      );
                    },
                  )
                : Row(
                    children: [
                      Icon(
                        paused ? Icons.pause_circle_outline : Icons.fiber_manual_record,
                        color: scheme.error,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(formatDuration(elapsed), style: tabular),
                    ],
                  ),
          ),
          // Laid out by reading direction: in Arabic delete sits on the right, send on the left.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                tooltip: l.t('delete'),
                icon: Icon(Icons.delete_outline, color: scheme.error, size: 28),
                onPressed: onDelete,
              ),
              IconButton.filledTonal(
                tooltip: paused ? l.t('resumeRecording') : l.t('pauseRecording'),
                icon: Icon(paused ? Icons.mic : Icons.pause_rounded),
                onPressed: onPause,
              ),
              FloatingActionButton.small(
                heroTag: null,
                elevation: 0,
                tooltip: l.t('send'),
                onPressed: onSend,
                child: const Icon(Icons.send_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecordingBar extends StatelessWidget {
  const _RecordingBar({required this.elapsed, required this.cancelling});

  final Duration elapsed;
  final bool cancelling;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(24)),
      child: Row(
        children: [
          Icon(cancelling ? Icons.delete_outline : Icons.fiber_manual_record, color: scheme.error, size: 20),
          const SizedBox(width: 8),
          Text(
            formatDuration(elapsed),
            style: const TextStyle(fontFeatures: [ui.FontFeature.tabularFigures()]),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              cancelling ? l.t('cancel') : '‹ ${l.t('cancel')} ›   ${l.t('releaseToSend')}',
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _DateChip extends StatelessWidget {
  const _DateChip({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final now = DateTime.now();
    final label = DateUtils.isSameDay(date, now)
        ? l.t('today')
        : DateUtils.isSameDay(date, now.subtract(const Duration(days: 1)))
        ? l.t('yesterday')
        : formatChatDate(context, date);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(label, style: Theme.of(context).textTheme.labelSmall),
      ),
    );
  }
}

class _ReplyBanner extends StatelessWidget {
  const _ReplyBanner({required this.icon, required this.name, required this.label, required this.onClose});

  final IconData icon;
  final String name;
  final String label;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 0),
      padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: BorderDirectional(start: BorderSide(color: scheme.primary, width: 4)),
      ),
      child: Row(
        children: [
          Icon(icon, color: scheme.primary, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600),
                ),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(icon: const Icon(Icons.close), onPressed: onClose),
        ],
      ),
    );
  }
}

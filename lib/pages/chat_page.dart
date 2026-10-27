import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import '../services/calls.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';
import '../widgets/message_bubble.dart';
import '../widgets/sticker_panel.dart';
import 'group_info_page.dart';

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

  final _text = TextEditingController();
  final _picker = ImagePicker();
  final _recorder = AudioRecorder();
  Map<String, Profile> _members = {};
  Profile? _peer;
  int _uploads = 0;

  bool _recording = false;
  bool _cancelRecording = false;
  DateTime? _recStart;
  Timer? _recTicker;

  @override
  void initState() {
    super.initState();
    _peer = widget.peer;
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
    _recTicker?.cancel();
    _recorder.dispose();
    _text.dispose();
    super.dispose();
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
    }
  }

  Future<void> _startRecording() async {
    if (!await _recorder.hasPermission()) {
      if (mounted) toast(context, L.of(context).t('micDenied'));
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000), path: path);
    HapticFeedback.mediumImpact();
    setState(() {
      _recording = true;
      _cancelRecording = false;
      _recStart = DateTime.now();
    });
    _recTicker = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
  }

  Future<void> _stopRecording() async {
    if (!_recording) return;
    _recTicker?.cancel();
    final path = await _recorder.stop();
    final ms = DateTime.now().difference(_recStart!).inMilliseconds;
    final cancel = _cancelRecording;
    setState(() => _recording = false);
    if (cancel || path == null || ms < 700) return;
    final reply = _takeReply();
    await _guard(() async {
      final bytes = await XFile(path).readAsBytes();
      final url = await Api.upload(bytes, 'm4a', 'audio/mp4');
      await Api.send(widget.conversationId, type: 'voice', mediaUrl: url, meta: {...reply, 'ms': ms});
    });
  }

  void _call(bool video) {
    final peer = _peer;
    if (widget.isGroup || peer == null) {
      toast(context, L.of(context).t('groupCallsSoon'));
      return;
    }
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
              : null,
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
                final msgs = snap.data;
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
                              onReply: (m) => setState(() => _replyTo = m),
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
          if (_replyTo != null)
            _ReplyBanner(
              name: _replyTo!.senderId == myId ? l.t('you') : (_members[_replyTo!.senderId]?.displayName ?? ''),
              label: lastMessageLabel(l, _replyTo!.type, _replyTo!.content),
              onClose: () => setState(() => _replyTo = null),
            ),
          if (_uploads > 0) LinearProgressIndicator(minHeight: 2, backgroundColor: scheme.surfaceContainerHighest),
          SafeArea(
            top: false,
            child: Padding(
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
                        ? _RecordingBar(start: _recStart!, cancelling: _cancelRecording)
                        : TextField(
                            controller: _text,
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
                          child: const Icon(Icons.send_rounded),
                        )
                      : GestureDetector(
                          onTap: () => toast(context, l.t('holdToRecord')),
                          onLongPressStart: (_) => _startRecording(),
                          onLongPressMoveUpdate: (d) {
                            final cancel = d.offsetFromOrigin.dx.abs() > 90;
                            if (cancel != _cancelRecording) setState(() => _cancelRecording = cancel);
                          },
                          onLongPressEnd: (_) => _stopRecording(),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: _recording ? 56 : 40,
                            height: _recording ? 56 : 40,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _recording ? scheme.error : scheme.primaryContainer,
                            ),
                            child: Icon(Icons.mic, color: _recording ? scheme.onError : scheme.onPrimaryContainer),
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

class _RecordingBar extends StatelessWidget {
  const _RecordingBar({required this.start, required this.cancelling});

  final DateTime start;
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
            formatDuration(DateTime.now().difference(start)),
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
  const _ReplyBanner({required this.name, required this.label, required this.onClose});

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
          Icon(Icons.reply, color: scheme.primary, size: 20),
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

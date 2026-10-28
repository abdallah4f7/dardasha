import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../l10n.dart';
import '../models.dart';
import '../pages/media_viewer.dart';
import '../pages/web_video_page.dart';
import '../services/api.dart';
import '../services/download.dart';
import '../services/link_preview.dart';
import 'common.dart';

const quickReactions = ['❤️', '😂', '😮', '😢', '👍', '🙏'];
const moreReactions = [
  '❤️',
  '😂',
  '😮',
  '😢',
  '👍',
  '🙏',
  '🔥',
  '😍',
  '🥰',
  '😎',
  '🤣',
  '😭',
  '😡',
  '🤯',
  '😱',
  '🤔',
  '🙄',
  '😴',
  '👏',
  '💪',
  '🤝',
  '👎',
  '💯',
  '✅',
  '🎉',
  '💔',
  '🥳',
  '🤡',
  '💀',
  '👀',
  '🫡',
  '🌹',
];

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.mine,
    this.senderName,
    this.compact = false,
    this.reactions = const [],
    required this.onReply,
    required this.onReact,
    required this.onEdit,
    required this.onDelete,
  });

  final Message message;
  final bool mine;
  final String? senderName;
  final bool compact;
  final List<Reaction> reactions;
  final void Function(Message) onReply;
  final void Function(String emoji) onReact;
  final void Function(Message) onEdit;
  final void Function(Message) onDelete;

  bool get _bare => message.type == 'sticker';

  bool get _downloadable =>
      message.mediaUrl != null && const {'image', 'video', 'voice', 'sticker'}.contains(message.type);

  String? get _myReaction => reactions.where((r) => r.userId == myId).firstOrNull?.emoji;

  Future<void> _menu(BuildContext context) async {
    final l = L.of(context);
    final m = message;
    final canSaveSticker = m.type == 'sticker' && m.mediaUrl != null;
    final mineEmoji = _myReaction;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Wrap(
          children: [
            if (m.type != 'call')
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final e in quickReactions)
                      _EmojiChoice(emoji: e, selected: e == mineEmoji, onTap: () => Navigator.pop(c, 'react:$e')),
                    IconButton.filledTonal(
                      tooltip: l.t('react'),
                      icon: const Icon(Icons.add),
                      onPressed: () => Navigator.pop(c, 'react+'),
                    ),
                  ],
                ),
              ),
            if (m.type != 'call')
              ListTile(
                leading: const Icon(Icons.reply),
                title: Text(l.t('reply')),
                onTap: () => Navigator.pop(c, 'reply'),
              ),
            if (m.type == 'text')
              ListTile(
                leading: const Icon(Icons.copy),
                title: Text(l.t('copy')),
                onTap: () => Navigator.pop(c, 'copy'),
              ),
            if (mine && m.type == 'text')
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(l.t('edit')),
                onTap: () => Navigator.pop(c, 'edit'),
              ),
            if (_downloadable)
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: Text(l.t('download')),
                onTap: () => Navigator.pop(c, 'download'),
              ),
            if (canSaveSticker)
              ListTile(
                leading: const Icon(Icons.bookmark_add_outlined),
                title: Text(l.t('saveSticker')),
                onTap: () => Navigator.pop(c, 'sticker'),
              ),
            if (mine)
              ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(c).colorScheme.error),
                title: Text(l.t('deleteMessage'), style: TextStyle(color: Theme.of(c).colorScheme.error)),
                onTap: () => Navigator.pop(c, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    if (action.startsWith('react:')) {
      onReact(action.substring(6));
      return;
    }
    if (action == 'react+') {
      final e = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (c) => SafeArea(
          child: GridView.count(
            crossAxisCount: 8,
            shrinkWrap: true,
            padding: const EdgeInsets.all(12),
            children: [
              for (final e in moreReactions)
                _EmojiChoice(emoji: e, selected: e == mineEmoji, onTap: () => Navigator.pop(c, e)),
            ],
          ),
        ),
      );
      if (e != null) onReact(e);
      return;
    }
    try {
      switch (action) {
        case 'reply':
          onReply(m);
        case 'edit':
          onEdit(m);
        case 'download':
          await downloadMessage(context, m);
        case 'copy':
          await Clipboard.setData(ClipboardData(text: m.content ?? ''));
          if (context.mounted) toast(context, l.t('copied'));
        case 'sticker':
          await Api.saveSticker(m.mediaUrl!);
          if (context.mounted) toast(context, l.t('stickerSaved'));
        case 'delete':
          onDelete(m);
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = mine ? scheme.primary : scheme.surfaceContainerHigh;
    final fg = mine ? scheme.onPrimary : scheme.onSurface;
    final maxW = MediaQuery.sizeOf(context).width * .78;
    const r = Radius.circular(18);
    const tail = Radius.circular(4);
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    // Tail corner sits on the sender's side.
    final tailOnRight = mine != isRtl;

    final time = Text(
      [
        if (message.meta['edited'] == true) L.of(context).t('edited'),
        formatTime(context, message.createdAt),
      ].join(' · '),
      style: TextStyle(fontSize: 11, color: (_bare ? scheme.onSurface : fg).withValues(alpha: .7)),
    );

    Widget body = switch (message.type) {
      'image' => _ImageContent(message: message, maxWidth: maxW),
      'video' => _VideoContent(message: message),
      'voice' => _VoiceContent(message: message, color: fg),
      'sticker' => _StickerContent(message: message),
      'call' => _CallContent(message: message, color: fg),
      _ => _TextContent(message: message, color: fg, mine: mine),
    };

    final padded = message.type == 'image' || message.type == 'video' || _bare;

    return Padding(
      padding: EdgeInsets.only(top: compact ? 2 : 8),
      child: Align(
        alignment: mine ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: GestureDetector(
            onLongPress: () => _menu(context),
            child: Column(
              crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (senderName != null)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 12, bottom: 2),
                    child: Text(
                      senderName!,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary),
                    ),
                  ),
                Container(
                  decoration: _bare
                      ? null
                      : BoxDecoration(
                          color: bg,
                          borderRadius: BorderRadius.only(
                            topLeft: r,
                            topRight: r,
                            bottomLeft: tailOnRight ? r : tail,
                            bottomRight: tailOnRight ? tail : r,
                          ),
                        ),
                  clipBehavior: Clip.antiAlias,
                  padding: padded ? const EdgeInsets.all(3) : const EdgeInsets.fromLTRB(12, 8, 12, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message.meta['reply'] is Map)
                        _ReplyQuote(
                          reply: Map<String, dynamic>.from(message.meta['reply'] as Map),
                          mine: mine && !_bare,
                        ),
                      body,
                      Padding(
                        padding: padded ? const EdgeInsets.fromLTRB(6, 2, 6, 2) : const EdgeInsets.only(top: 2),
                        child: time,
                      ),
                    ],
                  ),
                ),
                if (reactions.isNotEmpty)
                  Transform.translate(
                    offset: const Offset(0, -4),
                    child: _ReactionBar(reactions: reactions, mine: _myReaction, onTap: onReact),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmojiChoice extends StatelessWidget {
  const _EmojiChoice({required this.emoji, required this.selected, required this.onTap});

  final String emoji;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: selected
            ? BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, shape: BoxShape.circle)
            : null,
        child: Text(emoji, style: const TextStyle(fontSize: 28)),
      ),
    );
  }
}

/// Grouped reactions under a bubble, e.g. "❤️ 2  😂". Tapping toggles yours.
class _ReactionBar extends StatelessWidget {
  const _ReactionBar({required this.reactions, required this.mine, required this.onTap});

  final List<Reaction> reactions;
  final String? mine;
  final void Function(String) onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final counts = <String, int>{};
    for (final r in reactions) {
      counts[r.emoji] = (counts[r.emoji] ?? 0) + 1;
    }
    return Wrap(
      spacing: 4,
      children: [
        for (final e in counts.entries)
          GestureDetector(
            onTap: () => onTap(e.key),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: e.key == mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.surface, width: 2),
              ),
              child: Text(e.value > 1 ? '${e.key} ${e.value}' : e.key, style: const TextStyle(fontSize: 14)),
            ),
          ),
      ],
    );
  }
}

/// The quoted message shown at the top of a reply.
class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.reply, required this.mine});

  final Map<String, dynamic> reply;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final scheme = Theme.of(context).colorScheme;
    final fg = mine ? scheme.onPrimary : scheme.onSurface;
    final accent = mine ? scheme.onPrimary : scheme.primary;
    return Container(
      constraints: const BoxConstraints(minWidth: 140),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 10, 6),
      decoration: BoxDecoration(
        color: mine ? Colors.black.withValues(alpha: .15) : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: BorderDirectional(start: BorderSide(color: accent, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            reply['name'] as String? ?? '',
            style: TextStyle(color: accent, fontWeight: FontWeight.w600, fontSize: 12),
          ),
          Text(
            lastMessageLabel(l, reply['type'] as String?, reply['text'] as String?),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: fg.withValues(alpha: .85), fontSize: 13),
          ),
        ],
      ),
    );
  }
}

void openLink(BuildContext context, LinkPreview p) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => WebVideoPage(preview: p)));

class _TextContent extends StatefulWidget {
  const _TextContent({required this.message, required this.color, required this.mine});

  final Message message;
  final Color color;
  final bool mine;

  @override
  State<_TextContent> createState() => _TextContentState();
}

class _TextContentState extends State<_TextContent> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  List<InlineSpan> _spans(String text) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in RegExp(r'https?://[^\s<>"]+', caseSensitive: false).allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      final url = m.group(0)!;
      final rec = TapGestureRecognizer()
        ..onTap = () => openLink(
          context,
          LinkPreview(url: url, kind: LinkPreview.kindOf(url), videoId: LinkPreview.youtubeId(url)),
        );
      _recognizers.add(rec);
      spans.add(
        TextSpan(
          text: url,
          recognizer: rec,
          style: const TextStyle(decoration: TextDecoration.underline),
        ),
      );
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.message.meta['preview'];
    final text = widget.message.content ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (preview is Map)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: LinkPreviewCard(preview: LinkPreview.fromMap(Map<String, dynamic>.from(preview)), mine: widget.mine),
          ),
        Text.rich(
          TextSpan(children: _spans(text)),
          style: TextStyle(color: widget.color, fontSize: 16, height: 1.3),
        ),
      ],
    );
  }
}

/// Thumbnail card for a link. Tapping plays the video inside the app.
class LinkPreviewCard extends StatelessWidget {
  const LinkPreviewCard({super.key, required this.preview, required this.mine});

  final LinkPreview preview;
  final bool mine;

  IconData get _siteIcon => switch (preview.kind) {
    'youtube' => Icons.smart_display,
    'tiktok' => Icons.music_note,
    'snapchat' => Icons.camera,
    'instagram' => Icons.camera_alt_outlined,
    _ => Icons.link,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cardBg = mine ? Colors.black.withValues(alpha: .15) : scheme.surfaceContainerHighest;
    final fg = mine ? scheme.onPrimary : scheme.onSurface;
    return InkWell(
      onTap: () => openLink(context, preview),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 260,
        decoration: BoxDecoration(color: cardBg, borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (preview.image != null)
              AspectRatio(
                aspectRatio: preview.kind == 'tiktok' ? 3 / 4 : 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      imageUrl: preview.image!,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => Container(color: Colors.black26),
                    ),
                    if (preview.isVideo)
                      Center(
                        child: Container(
                          decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                          padding: const EdgeInsets.all(10),
                          child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 40),
                        ),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Icon(_siteIcon, size: 16, color: fg.withValues(alpha: .8)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (preview.site != null)
                          Text(preview.site!, style: TextStyle(fontSize: 11, color: fg.withValues(alpha: .7))),
                        if (preview.title != null)
                          Text(
                            preview.title!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.w600, color: fg, fontSize: 13),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImageContent extends StatelessWidget {
  const _ImageContent({required this.message, required this.maxWidth});

  final Message message;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final w = (message.meta['w'] as num?)?.toDouble() ?? 1;
    final h = (message.meta['h'] as num?)?.toDouble() ?? 1;
    final aspect = (w / h).clamp(.6, 1.8);
    final url = message.mediaUrl!;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ImageViewerPage(url: url, tag: message.id),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: SizedBox(
          width: 250,
          child: AspectRatio(
            aspectRatio: aspect,
            child: Hero(
              tag: message.id,
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, _) => Container(color: Colors.black12),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoContent extends StatelessWidget {
  const _VideoContent({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () =>
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoPlayerPage(url: message.mediaUrl!))),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Container(
          width: 250,
          height: 170,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF232A47), Color(0xFF0E1222)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: const Stack(
            children: [
              Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 58)),
              PositionedDirectional(start: 10, bottom: 8, child: Icon(Icons.videocam, color: Colors.white70, size: 18)),
            ],
          ),
        ),
      ),
    );
  }
}

class _StickerContent extends StatelessWidget {
  const _StickerContent({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    if (message.mediaUrl == null) {
      return Text(message.content ?? '', style: const TextStyle(fontSize: 96));
    }
    return CachedNetworkImage(
      imageUrl: message.mediaUrl!,
      width: 150,
      height: 150,
      fit: BoxFit.contain,
      placeholder: (_, _) => const SizedBox(width: 150, height: 150),
    );
  }
}

class _CallContent extends StatelessWidget {
  const _CallContent({required this.message, required this.color});

  final Message message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final video = message.meta['video'] == true;
    final secs = (message.meta['seconds'] as num?)?.toInt() ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(video ? Icons.videocam : Icons.call, color: secs == 0 ? Colors.redAccent : color),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.t(video ? 'videoCall' : 'voiceCall'),
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
            Text(
              secs == 0 ? l.t('noAnswer') : formatDuration(Duration(seconds: secs)),
              style: TextStyle(color: color.withValues(alpha: .8), fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }
}

class _VoiceContent extends StatefulWidget {
  const _VoiceContent({required this.message, required this.color});

  final Message message;
  final Color color;

  @override
  State<_VoiceContent> createState() => _VoiceContentState();
}

class _VoiceContentState extends State<_VoiceContent> {
  AudioPlayer? _player;

  Duration get _total => Duration(milliseconds: (widget.message.meta['ms'] as num?)?.toInt() ?? 0);

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    var p = _player;
    if (p == null) {
      p = _player = AudioPlayer();
      await p.setUrl(widget.message.mediaUrl!);
      p.playerStateStream.listen((s) {
        if (s.processingState == ProcessingState.completed) {
          p!.pause();
          p.seek(Duration.zero);
        }
      });
      setState(() {});
    }
    p.playing ? await p.pause() : await p.play();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    final p = _player;
    return SizedBox(
      width: 220,
      child: Row(
        children: [
          StreamBuilder<bool>(
            stream: p?.playingStream,
            builder: (_, s) => IconButton(
              icon: Icon((s.data ?? false) ? Icons.pause_rounded : Icons.play_arrow_rounded, color: c, size: 32),
              onPressed: _toggle,
            ),
          ),
          Expanded(
            child: StreamBuilder<Duration>(
              stream: p?.positionStream,
              builder: (_, s) {
                final total = p?.duration ?? _total;
                final pos = s.data ?? Duration.zero;
                final v = total.inMilliseconds == 0 ? 0.0 : (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        overlayShape: SliderComponentShape.noOverlay,
                        activeTrackColor: c,
                        inactiveTrackColor: c.withValues(alpha: .3),
                        thumbColor: c,
                      ),
                      child: Slider(value: v, onChanged: p == null ? null : (x) => p.seek(total * x)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatDuration(pos > Duration.zero ? pos : total),
                      style: TextStyle(color: c.withValues(alpha: .8), fontSize: 12),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

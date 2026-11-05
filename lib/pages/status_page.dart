import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../l10n.dart';
import '../models.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';
import '../widgets/report_sheet.dart';

/// One person's current statuses, oldest first.
class StatusGroup {
  StatusGroup(this.person, this.items);

  final Profile person;
  final List<Message> items;

  bool unseenBy(Set<String> seen) => items.any((m) => !seen.contains(m.id));
}

/// People with something unseen first, then whoever posted last.
List<List<Message>> sortStatuses(List<Message> feed, Set<String> seen) {
  final bySender = <String, List<Message>>{};
  for (final m in feed) {
    (bySender[m.senderId] ??= []).add(m);
  }
  bool unseen(List<Message> items) => items.any((m) => !seen.contains(m.id));
  return bySender.values.toList()..sort((a, b) {
    if (unseen(a) != unseen(b)) return unseen(a) ? -1 : 1;
    return b.last.createdAt.compareTo(a.last.createdAt);
  });
}

/// Which statuses this device has shown. Forgets the ones that are gone.
class StatusSeen {
  StatusSeen._();

  static const _key = 'seen_statuses';

  static Future<Set<String>> load(Iterable<String> current) async {
    final prefs = await SharedPreferences.getInstance();
    final seen = (prefs.getStringList(_key) ?? const <String>[]).toSet().intersection(current.toSet());
    await prefs.setStringList(_key, seen.toList());
    return seen;
  }

  static Future<void> add(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, {...?prefs.getStringList(_key), id}.toList());
  }
}

/// Under the app bar on the home page: my status, then everyone else's.
class StatusStrip extends StatelessWidget {
  const StatusStrip({
    super.key,
    required this.me,
    required this.mineCount,
    required this.groups,
    required this.seen,
    required this.onMine,
    required this.onOpen,
  });

  final Profile? me;
  final int mineCount;
  final List<StatusGroup> groups;
  final Set<String> seen;
  final VoidCallback onMine;
  final void Function(int index) onOpen;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 98,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        children: [
          _StatusCircle(
            name: l.t('myStatus'),
            avatarName: me?.displayName ?? '',
            url: me?.avatarUrl,
            ring: mineCount > 0 ? scheme.primary : null,
            add: true,
            onTap: onMine,
          ),
          for (final (i, g) in groups.indexed)
            _StatusCircle(
              name: g.person.displayName,
              avatarName: g.person.displayName,
              url: g.person.avatarUrl,
              ring: g.unseenBy(seen) ? scheme.primary : scheme.outlineVariant,
              onTap: () => onOpen(i),
            ),
        ],
      ),
    );
  }
}

class _StatusCircle extends StatelessWidget {
  const _StatusCircle({
    required this.name,
    required this.avatarName,
    required this.url,
    required this.ring,
    required this.onTap,
    this.add = false,
  });

  final String name;
  final String avatarName;
  final String? url;
  final Color? ring;
  final VoidCallback onTap;
  final bool add;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: SizedBox(
        width: 72,
        child: Column(
          children: [
            Stack(
              children: [
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: ring ?? Colors.transparent, width: 2),
                  ),
                  child: Avatar(name: avatarName, url: url, radius: 25),
                ),
                if (add)
                  PositionedDirectional(
                    end: 0,
                    bottom: 0,
                    child: CircleAvatar(
                      radius: 10,
                      backgroundColor: scheme.primary,
                      child: Icon(Icons.add, size: 16, color: scheme.onPrimary),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Plays people's statuses one after another, full screen.
class StatusViewerPage extends StatefulWidget {
  const StatusViewerPage({super.key, required this.groups, required this.start, required this.seen});

  final List<StatusGroup> groups;
  final int start;
  final Set<String> seen;

  @override
  State<StatusViewerPage> createState() => _StatusViewerPageState();
}

class _StatusViewerPageState extends State<StatusViewerPage> with SingleTickerProviderStateMixin {
  static const _still = Duration(seconds: 6);

  late int _group = widget.start;
  late int _item = _firstUnseen();
  VideoPlayerController? _video;
  AudioPlayer? _audio;
  late final AnimationController _progress = AnimationController(vsync: this, duration: _still)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _next();
    });

  StatusGroup get _current => widget.groups[_group];
  Message get _message => _current.items[_item];

  /// Picks up where they stopped: the oldest one not shown yet.
  int _firstUnseen() {
    final first = _current.items.indexWhere((m) => !widget.seen.contains(m.id));
    return first < 0 ? 0 : first;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _show());
  }

  @override
  void dispose() {
    _progress.dispose();
    _video?.dispose();
    _audio?.dispose();
    super.dispose();
  }

  void _clearMedia() {
    _video?.dispose();
    _audio?.dispose();
    _video = null;
    _audio = null;
  }

  /// Stills run on a timer; video and voice last as long as they play.
  Future<void> _show() async {
    final m = _message;
    widget.seen.add(m.id);
    StatusSeen.add(m.id);
    _clearMedia();
    _progress
      ..stop()
      ..reset()
      ..duration = _still;
    setState(() {});
    final url = m.mediaUrl;
    try {
      if (m.type == 'video' && url != null) {
        final c = VideoPlayerController.networkUrl(Uri.parse(url));
        _video = c;
        await c.initialize();
        if (!mounted || _video != c) return;
        if (c.value.duration > Duration.zero) _progress.duration = c.value.duration;
        setState(() {});
        c.play();
      } else if (m.type == 'voice' && url != null) {
        final a = AudioPlayer();
        _audio = a;
        final length = await a.setUrl(url);
        if (!mounted || _audio != a) return;
        if (length != null && length > Duration.zero) _progress.duration = length;
        a.play();
      }
    } catch (_) {
      if (!mounted || _message != m) return; // it couldn't load: move on after the usual time
    }
    _progress.forward();
  }

  void _next() {
    if (_item + 1 < _current.items.length) {
      _item++;
    } else if (_group + 1 < widget.groups.length) {
      _group++;
      _item = _firstUnseen();
    } else {
      Navigator.of(context).pop();
      return;
    }
    _show();
  }

  void _previous() {
    if (_item > 0) {
      _item--;
    } else if (_group > 0) {
      _group--;
      _item = _current.items.length - 1;
    }
    _show();
  }

  void _pause() {
    _progress.stop();
    _video?.pause();
    _audio?.pause();
  }

  void _resume() {
    _progress.forward();
    _video?.play();
    _audio?.play();
  }

  Future<void> _report() async {
    _pause();
    await reportMessage(context, _message);
    if (mounted) _resume();
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // The side the reading direction runs towards goes forward.
        onTapUp: (d) => (d.globalPosition.dx < width / 2) == rtl ? _next() : _previous(),
        onLongPressStart: (_) => _pause(),
        onLongPressEnd: (_) => _resume(),
        child: Stack(
          children: [
            Positioned.fill(child: _content(l)),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: Row(
                      children: [
                        for (var i = 0; i < _current.items.length; i++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              child: i == _item
                                  ? AnimatedBuilder(
                                      animation: _progress,
                                      builder: (_, _) => _bar(_progress.value),
                                    )
                                  : _bar(i < _item ? 1 : 0),
                            ),
                          ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: Avatar(name: _current.person.displayName, url: _current.person.avatarUrl, radius: 20),
                    title: Text(_current.person.displayName, style: const TextStyle(color: Colors.white)),
                    subtitle: Text(
                      formatTime(context, _message.createdAt),
                      style: const TextStyle(color: Colors.white70),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: l.t('reportMessage'),
                          icon: const Icon(Icons.flag_outlined, color: Colors.white),
                          onPressed: _report,
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () => Navigator.of(context).pop(),
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

  Widget _bar(double value) =>
      LinearProgressIndicator(value: value, minHeight: 3, color: Colors.white, backgroundColor: Colors.white30);

  Widget _content(L l) {
    final m = _message;
    final url = m.mediaUrl;
    const big = TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w600);
    return switch (m.type) {
      'image' || 'sticker' when url != null => Center(
        child: CachedNetworkImage(imageUrl: url, fit: BoxFit.contain),
      ),
      'video' => Center(
        child: _video?.value.isInitialized == true
            ? AspectRatio(aspectRatio: _video!.value.aspectRatio, child: VideoPlayer(_video!))
            : const CircularProgressIndicator(color: Colors.white),
      ),
      'voice' => const Center(child: Icon(Icons.graphic_eq, color: Colors.white, size: 96)),
      'file' when url != null => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file_outlined, color: Colors.white, size: 72),
            const SizedBox(height: 12),
            Text(m.content ?? '', style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
            TextButton(
              onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
              child: Text(l.t('openFile')),
            ),
          ],
        ),
      ),
      _ => Container(
        color: Theme.of(context).colorScheme.primary,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(32),
        child: Text(m.content ?? '', style: big, textAlign: TextAlign.center),
      ),
    };
  }
}

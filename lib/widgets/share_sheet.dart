import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import 'avatar.dart';
import 'common.dart';

const _channel = MethodChannel('dardasha/share');

bool get _android => !kIsWeb && Platform.isAndroid;

String _mime(Message m) {
  final ext = (m.mediaUrl ?? '').split('?').first.split('.').last.toLowerCase();
  return switch (m.type) {
    'image' || 'sticker' => ext == 'png' ? 'image/png' : (ext == 'webp' ? 'image/webp' : 'image/jpeg'),
    'video' => 'video/mp4',
    'voice' => 'audio/mp4',
    'file' => contentTypeFor(m.content ?? ''),
    _ => 'text/plain',
  };
}

/// Dardasha itself, five apps from this phone, and "more" for the system share sheet.
Future<void> shareMessage(BuildContext context, Message m) async {
  final l = L.of(context);
  final mime = _mime(m);
  List<_Target> targets = [];
  if (_android) {
    try {
      final list = await _channel.invokeListMethod<Map>('targets', {'mime': '${mime.split('/').first}/*', 'limit': 5});
      targets = [for (final t in list ?? const []) _Target.fromMap(t)];
    } catch (_) {}
  }
  if (!context.mounted) return;
  final picked = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              child: Text(l.t('share'), style: Theme.of(c).textTheme.titleLarge),
            ),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: .85,
              children: [
                _Choice(
                  label: l.t('appName'),
                  icon: Image.asset('assets/icon/icon.png', width: 48, height: 48),
                  onTap: () => Navigator.pop(c, 'app'),
                ),
                for (final t in targets)
                  _Choice(label: t.label, icon: Image.memory(t.icon, width: 48, height: 48), onTap: () => Navigator.pop(c, t)),
                _Choice(
                  label: l.t('more'),
                  icon: CircleAvatar(
                    radius: 24,
                    backgroundColor: Theme.of(c).colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.more_horiz),
                  ),
                  onTap: () => Navigator.pop(c, 'more'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;

  if (picked == 'app') {
    final sent = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ForwardPage(message: m)));
    if (sent == true && context.mounted) toast(context, l.t('sent'));
    return;
  }

  final text = m.type == 'text' ? m.content : null;
  String? path;
  if (m.mediaUrl != null && !kIsWeb) {
    toast(context, '${l.t('share')}…');
    path = await _download(m);
  }
  if (picked is _Target) {
    await _channel.invokeMethod('send', {
      'package': picked.package,
      'activity': picked.activity,
      'mime': mime,
      'text': text,
      'path': path,
    });
  } else {
    await SharePlus.instance.share(
      path != null
          ? ShareParams(files: [XFile(path, mimeType: mime)])
          : ShareParams(text: text ?? m.mediaUrl),
    );
  }
}

Future<String> _download(Message m) async {
  final res = await http.get(Uri.parse(m.mediaUrl!));
  if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
  final dir = Directory('${(await getTemporaryDirectory()).path}/share')..createSync(recursive: true);
  final ext = Uri.parse(m.mediaUrl!).path.split('.').last;
  final file = File('${dir.path}/${m.id}.$ext');
  await file.writeAsBytes(res.bodyBytes);
  return file.path;
}

class _Target {
  _Target(this.package, this.activity, this.label, this.icon);

  final String package;
  final String activity;
  final String label;
  final Uint8List icon;

  factory _Target.fromMap(Map m) =>
      _Target(m['package'] as String, m['activity'] as String, m['label'] as String, m['icon'] as Uint8List);
}

class _Choice extends StatelessWidget {
  const _Choice({required this.label, required this.icon, required this.onTap});

  final String label;
  final Widget icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(12), child: icon),
          const SizedBox(height: 8),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

/// Pick a chat to forward [message] into.
class ForwardPage extends StatefulWidget {
  const ForwardPage({super.key, required this.message});

  final Message message;

  @override
  State<ForwardPage> createState() => _ForwardPageState();
}

class _ForwardPageState extends State<ForwardPage> {
  List<Conversation>? _convs;
  Map<String, Profile> _peers = {};
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final (rows, peers) = await (
        db.from('conversations').select().order('last_message_at', ascending: false).then((r) => r),
        Api.dmPeers(),
      ).wait;
      if (!mounted) return;
      setState(() {
        _convs = rows.map(Conversation.fromMap).toList();
        _peers = peers;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _send(Conversation c) async {
    setState(() => _sending = true);
    try {
      await Api.forward(widget.message, c.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final convs = _convs;
    return Scaffold(
      appBar: AppBar(title: Text(l.t('shareTo'))),
      body: convs == null || _sending
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                for (final c in convs)
                  if (c.isGroup || _peers[c.id] != null)
                    ListTile(
                      leading: Avatar(
                        name: c.isGroup ? (c.name ?? '') : _peers[c.id]!.displayName,
                        url: c.isGroup ? c.avatarUrl : _peers[c.id]!.avatarUrl,
                        group: c.isGroup,
                      ),
                      title: Text(c.isGroup ? (c.name ?? '') : _peers[c.id]!.displayName),
                      trailing: const Icon(Icons.send_rounded),
                      onTap: () => _send(c),
                    ),
              ],
            ),
    );
  }
}

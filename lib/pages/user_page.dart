import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import '../services/calls.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';
import 'chat_page.dart';
import 'media_viewer.dart';

/// Someone else's profile: photo, names, and quick actions.
class UserPage extends StatefulWidget {
  const UserPage({super.key, required this.user, this.fromConversationId});

  final Profile user;

  /// Set when opened from the DM with this person, so "Message" just goes back.
  final String? fromConversationId;

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> {
  Friendship? _friendship;
  bool _loaded = false;
  bool _busy = false;

  Profile get u => widget.user;

  @override
  void initState() {
    super.initState();
    _loadFriendship();
  }

  Future<void> _loadFriendship() async {
    try {
      final all = await Api.friendships();
      if (!mounted) return;
      setState(() {
        _friendship = all.where((f) => f.other(myId).id == u.id).firstOrNull;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _loadFriendship();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _message() async {
    if (widget.fromConversationId != null) return Navigator.of(context).pop();
    try {
      final id = await Api.openDm(u.id);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatPage(conversationId: id, isGroup: false, title: u.displayName, avatarUrl: u.avatarUrl, peer: u),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _call(bool video) async {
    try {
      final id = widget.fromConversationId ?? await Api.openDm(u.id);
      if (!mounted) return;
      await CallService.instance.call(context, u, video: video, conversationId: id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _friendButton(L l) {
    final f = _friendship;
    if (!_loaded) return const SizedBox(height: 40);
    if (f == null) {
      return FilledButton.tonalIcon(
        onPressed: _busy ? null : () => _run(() => Api.requestFriend(u.id)),
        icon: const Icon(Icons.person_add_alt_1),
        label: Text(l.t('addFriend')),
      );
    }
    if (f.incoming(myId)) {
      return FilledButton.icon(
        onPressed: _busy ? null : () => _run(() => Api.acceptFriend(u.id)),
        icon: const Icon(Icons.check),
        label: Text(l.t('accept')),
      );
    }
    return OutlinedButton.icon(
      onPressed: null,
      icon: Icon(f.accepted ? Icons.people : Icons.schedule),
      label: Text(l.t(f.accepted ? 'isFriend' : 'requested')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isMe = u.id == myId;
    final heroTag = 'avatar-${u.id}';
    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        children: [
          const SizedBox(height: 8),
          Center(
            child: GestureDetector(
              onTap: u.avatarUrl == null
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => ImageViewerPage(url: u.avatarUrl!, tag: heroTag)),
                    ),
              child: Hero(
                tag: heroTag,
                child: Avatar(name: u.displayName, url: u.avatarUrl, radius: 64),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            u.displayName,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (u.username.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '@${u.username}',
              textAlign: TextAlign.center,
              textDirection: TextDirection.ltr,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
          if (!isMe) ...[
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _Action(icon: Icons.chat_bubble_outline, label: l.t('message'), onTap: _message),
                _Action(icon: Icons.call_outlined, label: l.t('voiceCall'), onTap: () => _call(false)),
                _Action(icon: Icons.videocam_outlined, label: l.t('videoCall'), onTap: () => _call(true)),
              ],
            ),
            const SizedBox(height: 24),
            Center(child: _friendButton(l)),
          ],
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        width: 96,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Icon(icon, color: scheme.primary),
            const SizedBox(height: 6),
            Text(label, style: Theme.of(context).textTheme.labelMedium, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

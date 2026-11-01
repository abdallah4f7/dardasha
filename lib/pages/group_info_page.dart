import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';
import 'new_chat_page.dart';
import 'user_page.dart';

/// What changed while the page was open, for the chat to show.
typedef GroupInfoResult = ({String name, String? avatarUrl});

class GroupInfoPage extends StatefulWidget {
  const GroupInfoPage({super.key, required this.conversationId, required this.name, this.avatarUrl});

  final String conversationId;
  final String name;
  final String? avatarUrl;

  @override
  State<GroupInfoPage> createState() => _GroupInfoPageState();
}

class _GroupInfoPageState extends State<GroupInfoPage> {
  List<Profile>? _members;
  Set<String> _owners = {};
  String? _mainOwner;
  late String _name = widget.name;
  late String? _avatarUrl = widget.avatarUrl;
  bool _busy = false;

  bool get _isOwner => _owners.contains(myId);
  bool get _isMainOwner => _mainOwner == myId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final (m, owners, main) = await (
      Api.members(widget.conversationId),
      Api.admins(widget.conversationId),
      Api.groupCreator(widget.conversationId),
    ).wait;
    // The main owner first, then the other owners, then everyone else.
    int rank(Profile p) => p.id == main ? 0 : (owners.contains(p.id) ? 1 : 2);
    m.sort((a, b) => rank(a) - rank(b));
    if (mounted) {
      setState(() {
        _members = m;
        _owners = owners;
        _mainOwner = main;
      });
    }
  }

  void _close() => Navigator.of(context).pop<GroupInfoResult>((name: _name, avatarUrl: _avatarUrl));

  Future<void> _guard(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final ids = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(builder: (_) => NewChatPage(pickMany: true, exclude: _members!.map((m) => m.id).toSet())),
    );
    if (ids == null || ids.isEmpty) return;
    await _guard(() async {
      await Api.addMembers(widget.conversationId, ids);
      await _load();
    });
  }

  Future<void> _changePhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 512, imageQuality: 85);
    if (x == null) return;
    await _guard(() async {
      final url = await Api.upload(await x.readAsBytes(), 'jpg', 'image/jpeg');
      await Api.updateGroup(widget.conversationId, avatarUrl: url);
      setState(() => _avatarUrl = url);
    });
  }

  Future<void> _rename() async {
    final l = L.of(context);
    final controller = TextEditingController(text: _name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.t('groupName')),
        content: TextField(controller: controller, autofocus: true, maxLength: 40),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(l.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, controller.text.trim()), child: Text(l.t('save'))),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == _name) return;
    await _guard(() async {
      await Api.updateGroup(widget.conversationId, name: name);
      setState(() => _name = name);
    });
  }

  Future<bool> _confirm(String title, String action) async {
    final l = L.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(title),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.t('cancel'))),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
                onPressed: () => Navigator.pop(c, true),
                child: Text(action),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _memberMenu(Profile m) async {
    final l = L.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(l.t('viewProfile')),
              onTap: () => Navigator.pop(c, 'profile'),
            ),
            // Nobody but the main owner themselves touches the main owner.
            if (_isOwner && m.id != _mainOwner) ...[
              if (_owners.contains(m.id))
                ListTile(
                  leading: const Icon(Icons.remove_moderator_outlined),
                  title: Text(l.t('removeOwner')),
                  onTap: () => Navigator.pop(c, 'unowner'),
                )
              else
                ListTile(
                  leading: const Icon(Icons.add_moderator_outlined),
                  title: Text(l.t('makeOwner')),
                  onTap: () => Navigator.pop(c, 'owner'),
                ),
              if (_isMainOwner)
                ListTile(
                  leading: const Icon(Icons.swap_horiz_rounded),
                  title: Text(l.t('transferOwnership')),
                  onTap: () => Navigator.pop(c, 'transfer'),
                ),
              ListTile(
                leading: Icon(Icons.person_remove_outlined, color: Theme.of(c).colorScheme.error),
                title: Text(l.t('removeFromGroup'), style: TextStyle(color: Theme.of(c).colorScheme.error)),
                onTap: () => Navigator.pop(c, 'remove'),
              ),
            ],
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'profile':
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => UserPage(user: m)));
      case 'owner' || 'unowner':
        await _guard(() async {
          await Api.setOwner(widget.conversationId, m.id, choice == 'owner');
          await _load();
        });
      case 'transfer':
        if (!await _confirm(l.t('transferOwnershipQ').replaceAll('{name}', m.displayName), l.t('transfer'))) return;
        await _guard(() async {
          await Api.transferGroup(widget.conversationId, m.id);
          await _load();
        });
      case 'remove':
        if (!await _confirm(l.t('removeFromGroupQ').replaceAll('{name}', m.displayName), l.t('remove'))) return;
        await _guard(() async {
          await Api.removeMember(widget.conversationId, m.id);
          await _load();
        });
    }
  }

  Future<void> _deleteGroup() async {
    final l = L.of(context);
    if (!await _confirm(l.t('deleteGroupQ'), l.t('deleteGroup'))) return;
    await _guard(() async {
      await Api.deleteGroup(widget.conversationId);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final scheme = Theme.of(context).colorScheme;
    final members = _members;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.t('groupInfo')),
          leading: BackButton(onPressed: _close),
          bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator()) : null,
        ),
        body: ListView(
          children: [
            const SizedBox(height: 24),
            Center(
              child: GestureDetector(
                onTap: _busy ? null : _changePhoto,
                child: Stack(
                  children: [
                    Avatar(name: _name, url: _avatarUrl, radius: 48, group: _avatarUrl == null),
                    PositionedDirectional(
                      end: 0,
                      bottom: 0,
                      child: CircleAvatar(
                        radius: 16,
                        backgroundColor: scheme.primary,
                        child: Icon(Icons.camera_alt, size: 16, color: scheme.onPrimary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _busy ? null : _rename,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: Text(_name, style: Theme.of(context).textTheme.headlineSmall)),
                      const SizedBox(width: 6),
                      Icon(Icons.edit_outlined, size: 18, color: scheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            ListTile(
              title: Text(
                '${l.t('members')} (${members?.length ?? 0})',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person_add)),
              title: Text(l.t('addMembers')),
              onTap: members == null || _busy ? null : _add,
            ),
            if (members == null) const Center(child: CircularProgressIndicator()),
            for (final m in members ?? <Profile>[])
              ListTile(
                leading: Avatar(name: m.displayName, url: m.avatarUrl),
                title: Text(m.id == myId ? l.t('you') : m.displayName),
                subtitle: Text('@${m.username}', textDirection: TextDirection.ltr),
                trailing: _owners.contains(m.id)
                    ? Chip(
                        label: Text(l.t(m.id == _mainOwner ? 'mainOwner' : 'groupOwner')),
                        visualDensity: VisualDensity.compact,
                        side: BorderSide.none,
                        backgroundColor: scheme.primaryContainer,
                      )
                    : null,
                onTap: m.id == myId ? null : () => _memberMenu(m),
                onLongPress: m.id == myId ? null : () => _memberMenu(m),
              ),
            const Divider(),
            ListTile(
              leading: Icon(Icons.exit_to_app, color: scheme.error),
              title: Text(l.t('leaveGroup'), style: TextStyle(color: scheme.error)),
              onTap: () async {
                await Api.leave(widget.conversationId);
                if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
            if (_isMainOwner)
              ListTile(
                leading: Icon(Icons.delete_forever_outlined, color: scheme.error),
                title: Text(l.t('deleteGroup'), style: TextStyle(color: scheme.error)),
                onTap: _busy ? null : _deleteGroup,
              ),
          ],
        ),
      ),
    );
  }
}

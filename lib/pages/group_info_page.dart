import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';
import 'new_chat_page.dart';
import 'user_page.dart';

class GroupInfoPage extends StatefulWidget {
  const GroupInfoPage({super.key, required this.conversationId, required this.name});

  final String conversationId;
  final String name;

  @override
  State<GroupInfoPage> createState() => _GroupInfoPageState();
}

class _GroupInfoPageState extends State<GroupInfoPage> {
  List<Profile>? _members;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await Api.members(widget.conversationId);
    if (mounted) setState(() => _members = m);
  }

  Future<void> _add() async {
    final ids = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(builder: (_) => NewChatPage(pickMany: true, exclude: _members!.map((m) => m.id).toSet())),
    );
    if (ids == null || ids.isEmpty) return;
    try {
      await Api.addMembers(widget.conversationId, ids);
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final members = _members;
    return Scaffold(
      appBar: AppBar(title: Text(l.t('groupInfo'))),
      body: ListView(
        children: [
          const SizedBox(height: 24),
          Center(child: Avatar(name: widget.name, radius: 48, group: true)),
          const SizedBox(height: 12),
          Center(child: Text(widget.name, style: Theme.of(context).textTheme.headlineSmall)),
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
            onTap: members == null ? null : _add,
          ),
          if (members == null) const Center(child: CircularProgressIndicator()),
          for (final m in members ?? <Profile>[])
            ListTile(
              leading: Avatar(name: m.displayName, url: m.avatarUrl),
              title: Text(m.id == myId ? l.t('you') : m.displayName),
              subtitle: Text('@${m.username}', textDirection: TextDirection.ltr),
              onTap: m.id == myId
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => UserPage(user: m))),
            ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.exit_to_app, color: Theme.of(context).colorScheme.error),
            title: Text(l.t('leaveGroup'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () async {
              await Api.leave(widget.conversationId);
              if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
        ],
      ),
    );
  }
}

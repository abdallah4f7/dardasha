import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';
import 'chat_page.dart';

/// Search users. In normal mode tapping a user opens a DM; in [pickMany] mode
/// (new group / add members) users are selected and returned.
class NewChatPage extends StatefulWidget {
  const NewChatPage({super.key, this.pickMany = false, this.groupMode = false, this.exclude = const {}});

  final bool pickMany;
  final bool groupMode;
  final Set<String> exclude;

  @override
  State<NewChatPage> createState() => _NewChatPageState();
}

class _NewChatPageState extends State<NewChatPage> {
  final _query = TextEditingController();
  final _groupName = TextEditingController();
  final Map<String, Profile> _selected = {};
  List<Profile> _results = [];
  Timer? _debounce;
  bool _busy = false;

  bool get _multi => widget.pickMany || widget.groupMode;

  List<Profile> _friends = [];

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  Future<void> _loadFriends() async {
    try {
      final all = await Api.friendships();
      _friends = [for (final f in all) if (f.accepted) f.other(myId)];
      await _search(_query.text);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(q));
  }

  /// Friends are listed, and filtered by the search; anyone else shows up only
  /// once their username is typed (almost) in full.
  Future<void> _search(String q) async {
    try {
      final needle = q.trim().replaceFirst('@', '').toLowerCase();
      final friends = _friends.where(
        (p) => p.username.toLowerCase().contains(needle) || p.displayName.toLowerCase().contains(needle),
      );
      final ids = {for (final p in friends) p.id};
      final others = (await Api.searchUsers(q)).where((p) => !ids.contains(p.id));
      if (!mounted) return;
      setState(() => _results = [...friends, ...others].where((p) => !widget.exclude.contains(p.id)).toList());
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _openDm(Profile p) async {
    setState(() => _busy = true);
    try {
      final id = await Api.openDm(p.id);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) =>
              ChatPage(conversationId: id, isGroup: false, title: p.displayName, avatarUrl: p.avatarUrl, peer: p),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _done() async {
    if (widget.pickMany) {
      Navigator.of(context).pop(_selected.keys.toList());
      return;
    }
    final name = _groupName.text.trim();
    if (name.isEmpty || _selected.isEmpty) return;
    setState(() => _busy = true);
    try {
      final id = await Api.createGroup(name, _selected.keys.toList());
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatPage(conversationId: id, isGroup: true, title: name),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final title = widget.pickMany
        ? l.t('addMembers')
        : widget.groupMode
        ? l.t('newGroup')
        : l.t('newChat');
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      floatingActionButton: _multi && _selected.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : _done,
              icon: const Icon(Icons.check),
              label: Text(widget.pickMany ? l.t('save') : l.t('create')),
            )
          : null,
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (widget.groupMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _groupName,
                decoration: InputDecoration(hintText: l.t('groupName'), prefixIcon: const Icon(Icons.group)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _query,
              onChanged: _onChanged,
              decoration: InputDecoration(hintText: l.t('searchUsers'), prefixIcon: const Icon(Icons.search)),
            ),
          ),
          if (!_multi)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.group_add)),
              title: Text(l.t('newGroup'), style: const TextStyle(fontWeight: FontWeight.w600)),
              onTap: () =>
                  Navigator.of(context)
                      .pushReplacement(MaterialPageRoute(builder: (_) => const NewChatPage(groupMode: true))),
            ),
          if (_multi && _selected.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final p in _selected.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: InputChip(
                        avatar: Avatar(name: p.displayName, url: p.avatarUrl, radius: 12),
                        label: Text(p.displayName),
                        onDeleted: () => setState(() => _selected.remove(p.id)),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (_, i) {
                final p = _results[i];
                final leading = Avatar(name: p.displayName, url: p.avatarUrl);
                if (_multi) {
                  return CheckboxListTile(
                    secondary: leading,
                    title: Text(p.displayName),
                    subtitle: Text('@${p.username}', textDirection: TextDirection.ltr),
                    value: _selected.containsKey(p.id),
                    onChanged: (v) => setState(() => v! ? _selected[p.id] = p : _selected.remove(p.id)),
                  );
                }
                return ListTile(
                  leading: leading,
                  title: Text(p.displayName),
                  subtitle: Text('@${p.username}', textDirection: TextDirection.ltr),
                  onTap: _busy ? null : () => _openDm(p),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

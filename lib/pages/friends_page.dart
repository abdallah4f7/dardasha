import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';
import 'chat_page.dart';

/// Friends list, friend requests, and search-to-add.
class FriendsPage extends StatefulWidget {
  const FriendsPage({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  State<FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends State<FriendsPage> {
  List<Friendship>? _all;
  final _query = TextEditingController();
  List<Profile> _results = [];
  Timer? _debounce;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final f = await Api.friendships();
      if (mounted) setState(() => _all = f);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _onQuery(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      if (q.trim().isEmpty) {
        setState(() => _results = []);
        return;
      }
      try {
        final r = await Api.searchUsers(q);
        if (mounted) setState(() => _results = r);
      } catch (e) {
        if (mounted) showError(context, e);
      }
    });
  }

  Friendship? _with(String userId) =>
      _all?.where((f) => f.requesterId == userId || f.addresseeId == userId).firstOrNull;

  Future<void> _do(String userId, Future<void> Function() action, {String? success}) async {
    setState(() => _busy.add(userId));
    try {
      await action();
      await _load();
      if (success != null && mounted) toast(context, L.of(context).t(success));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy.remove(userId));
    }
  }

  Future<void> _openChat(Profile p) async {
    try {
      final id = await Api.openDm(p.id);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              ChatPage(conversationId: id, isGroup: false, title: p.displayName, avatarUrl: p.avatarUrl, peer: p),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// The right button for a user in search results, depending on friendship state.
  Widget _actionFor(Profile p) {
    final l = L.of(context);
    if (_busy.contains(p.id)) {
      return const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2));
    }
    final f = _with(p.id);
    if (f == null) {
      return FilledButton.tonalIcon(
        icon: const Icon(Icons.person_add_alt_1, size: 18),
        label: Text(l.t('addFriend')),
        onPressed: () => _do(p.id, () => Api.requestFriend(p.id), success: 'requestSent'),
      );
    }
    if (f.accepted) {
      return OutlinedButton(onPressed: () => _openChat(p), child: Text(l.t('message')));
    }
    if (f.incoming(myId)) {
      return FilledButton(onPressed: () => _do(p.id, () => Api.acceptFriend(p.id)), child: Text(l.t('accept')));
    }
    return OutlinedButton(onPressed: () => _do(p.id, () => Api.removeFriendship(f)), child: Text(l.t('requested')));
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final all = _all;
    final friends = all?.where((f) => f.accepted).toList() ?? [];
    final incoming = all?.where((f) => f.incoming(myId)).toList() ?? [];
    final outgoing = all?.where((f) => !f.accepted && f.requesterId == myId).toList() ?? [];

    Widget empty(String key) => ListView(
      children: [
        const SizedBox(height: 120),
        Text(l.t(key), textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
      ],
    );

    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.t('friends')),
          bottom: TabBar(
            tabs: [
              Tab(text: l.t('friends')),
              Tab(
                child: Badge(
                  isLabelVisible: incoming.isNotEmpty,
                  label: Text('${incoming.length}'),
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text(l.t('requests'))),
                ),
              ),
              Tab(text: l.t('addFriends')),
            ],
          ),
        ),
        body: all == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  // Friends
                  RefreshIndicator(
                    onRefresh: _load,
                    child: friends.isEmpty
                        ? empty('noFriends')
                        : ListView(
                            children: [
                              for (final f in friends)
                                Builder(
                                  builder: (context) {
                                    final p = f.other(myId);
                                    return ListTile(
                                      leading: Avatar(name: p.displayName, url: p.avatarUrl),
                                      title: Text(p.displayName),
                                      subtitle: Text('@${p.username}', textDirection: TextDirection.ltr),
                                      onTap: () => _openChat(p),
                                      trailing: PopupMenuButton<String>(
                                        onSelected: (_) => _do(p.id, () => Api.removeFriendship(f)),
                                        itemBuilder: (_) => [
                                          PopupMenuItem(value: 'remove', child: Text(l.t('removeFriend'))),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                            ],
                          ),
                  ),
                  // Requests
                  RefreshIndicator(
                    onRefresh: _load,
                    child: incoming.isEmpty && outgoing.isEmpty
                        ? empty('noRequests')
                        : ListView(
                            children: [
                              if (incoming.isNotEmpty) ListTile(dense: true, title: Text(l.t('incoming'))),
                              for (final f in incoming)
                                ListTile(
                                  leading: Avatar(name: f.requester.displayName, url: f.requester.avatarUrl),
                                  title: Text(f.requester.displayName),
                                  subtitle: Text('@${f.requester.username}', textDirection: TextDirection.ltr),
                                  trailing: _busy.contains(f.requesterId)
                                      ? const SizedBox.square(
                                          dimension: 24,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        )
                                      : Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton.filledTonal(
                                              tooltip: l.t('decline'),
                                              icon: const Icon(Icons.close),
                                              onPressed: () => _do(f.requesterId, () => Api.removeFriendship(f)),
                                            ),
                                            const SizedBox(width: 4),
                                            IconButton.filled(
                                              tooltip: l.t('accept'),
                                              icon: const Icon(Icons.check),
                                              onPressed: () =>
                                                  _do(f.requesterId, () => Api.acceptFriend(f.requesterId)),
                                            ),
                                          ],
                                        ),
                                ),
                              if (outgoing.isNotEmpty) ListTile(dense: true, title: Text(l.t('outgoing'))),
                              for (final f in outgoing)
                                ListTile(
                                  leading: Avatar(name: f.addressee.displayName, url: f.addressee.avatarUrl),
                                  title: Text(f.addressee.displayName),
                                  subtitle: Text('@${f.addressee.username}', textDirection: TextDirection.ltr),
                                  trailing: TextButton(
                                    onPressed: () => _do(f.addresseeId, () => Api.removeFriendship(f)),
                                    child: Text(l.t('cancelRequest')),
                                  ),
                                ),
                            ],
                          ),
                  ),
                  // Add
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: TextField(
                          controller: _query,
                          autofocus: widget.initialTab == 2,
                          onChanged: _onQuery,
                          textDirection: TextDirection.ltr,
                          decoration: InputDecoration(
                            hintText: l.t('searchUsers'),
                            prefixIcon: const Icon(Icons.search),
                            prefixText: '@',
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          children: [
                            for (final p in _results)
                              ListTile(
                                leading: Avatar(name: p.displayName, url: p.avatarUrl),
                                title: Text(p.displayName),
                                subtitle: Text('@${p.username}', textDirection: TextDirection.ltr),
                                trailing: _actionFor(p),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

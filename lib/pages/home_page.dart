import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';
import 'chat_page.dart';
import 'friends_page.dart';
import 'new_chat_page.dart';
import 'profile_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Conversation>? _convs;
  Map<String, Profile> _peers = {};
  Profile? _me;
  int _requests = 0;
  RealtimeChannel? _channel;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
    _channel = db
        .channel('home:$myId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'conversations',
          callback: (_) => _reload(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'conversation_members',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: myId),
          callback: (_) => _reload(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'friendships',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'addressee', value: myId),
          callback: (_) => _reload(),
        )
        .subscribe();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_channel != null) db.removeChannel(_channel!);
    super.dispose();
  }

  void _reload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  Future<void> _load() async {
    try {
      final (rows, peers, me, requests) = await (
        db.from('conversations').select().order('last_message_at', ascending: false).then((r) => r),
        Api.dmPeers(),
        Api.profile(myId),
        Api.pendingRequestCount(),
      ).wait;
      if (!mounted) return;
      setState(() {
        _convs = rows.map(Conversation.fromMap).toList();
        _peers = peers;
        _me = me;
        _requests = requests;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _open(Conversation c) {
    final peer = _peers[c.id];
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          conversationId: c.id,
          isGroup: c.isGroup,
          title: c.isGroup ? (c.name ?? '') : (peer?.displayName ?? ''),
          avatarUrl: c.isGroup ? c.avatarUrl : peer?.avatarUrl,
          peer: peer,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final convs = _convs;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.t('appName'), style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: l.t('addFriends'),
            icon: Badge(
              isLabelVisible: _requests > 0,
              label: Text('$_requests'),
              child: const Icon(Icons.person_add_alt_1_outlined),
            ),
            onPressed: () async {
              await Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => FriendsPage(initialTab: _requests > 0 ? 1 : 2)));
              _load();
            },
          ),
          IconButton(
            tooltip: l.t('profile'),
            icon: Avatar(name: _me?.displayName ?? '', url: _me?.avatarUrl, radius: 16),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProfilePage()));
              _load();
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: l.t('newChat'),
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewChatPage()));
          _load();
        },
        child: const Icon(Icons.chat_rounded),
      ),
      body: convs == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: convs.isEmpty
                  ? ListView(
                      children: [
                        const SizedBox(height: 160),
                        Text(l.t('noChats'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
                      ],
                    )
                  : ListView.builder(
                      itemCount: convs.length,
                      itemBuilder: (_, i) {
                        final c = convs[i];
                        final peer = _peers[c.id];
                        final title = c.isGroup ? (c.name ?? '') : (peer?.displayName ?? '…');
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          leading: Avatar(
                            name: title,
                            url: c.isGroup ? c.avatarUrl : peer?.avatarUrl,
                            radius: 26,
                            group: c.isGroup && c.avatarUrl == null,
                          ),
                          title: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            lastMessageLabel(l, c.lastMessageType, c.lastMessageText),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            formatChatDate(context, c.lastMessageAt),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          onTap: () => _open(c),
                        );
                      },
                    ),
            ),
    );
  }
}

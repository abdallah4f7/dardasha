import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import '../services/updater.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';
import 'chat_page.dart';
import 'friends_page.dart';
import 'new_chat_page.dart';
import 'profile_page.dart';
import 'reports_page.dart';
import 'review_page.dart';
import 'status_page.dart';

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
  int? _openReports; // null: not a moderator
  int _myStatuses = 0;
  List<StatusGroup> _statuses = [];
  Set<String> _seenStatuses = {};
  RealtimeChannel? _channel;
  Timer? _debounce;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _load();
    // Other people's statuses reach no table this page can listen to.
    _statusTimer = Timer.periodic(const Duration(minutes: 1), (_) => _loadStatuses());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Updater.check(context);
      _showModerationNotice();
    });
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
    _statusTimer?.cancel();
    if (_channel != null) db.removeChannel(_channel!);
    ReviewDesk.stop();
    super.dispose();
  }

  void _reload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  Future<void> _load() async {
    try {
      final (rows, peers, me, requests, openReports) = await (
        db.from('conversations').select().order('last_message_at', ascending: false).then((r) => r),
        Api.dmPeers(),
        Api.profile(myId),
        Api.pendingRequestCount(),
        Api.openReportCount(),
      ).wait;
      if (!mounted) return;
      setState(() {
        _convs = rows.where((r) => r['is_status'] != true).map(Conversation.fromMap).toList();
        _peers = peers;
        _me = me;
        _requests = requests;
        _openReports = openReports;
      });
      // Moderators review the photos and videos the checks weren't sure of.
      if (openReports != null) ReviewDesk.start();
      await _loadStatuses();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Quiet on failure: the chats are what matter, and it tries again soon.
  Future<void> _loadStatuses() async {
    try {
      final (feed, mine) = await (Api.statusFeed(), Api.myStatusCount()).wait;
      final seen = await StatusSeen.load(feed.map((m) => m.id));
      final groups = <StatusGroup>[];
      for (final items in sortStatuses(feed, seen)) {
        final person = await Api.profile(items.first.senderId);
        if (person != null) groups.add(StatusGroup(person, items));
      }
      if (!mounted) return;
      setState(() {
        _statuses = groups;
        _myStatuses = mine;
        _seenStatuses = seen;
      });
    } catch (_) {}
  }

  Future<void> _openMyStatus() async {
    final l = L.of(context);
    try {
      final id = await Api.myStatusConversation();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatPage(
            conversationId: id,
            isGroup: false,
            isStatus: true,
            title: l.t('myStatus'),
            avatarUrl: _me?.avatarUrl,
          ),
        ),
      );
      _loadStatuses();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _openStatus(int index) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StatusViewerPage(groups: _statuses, start: index, seen: {..._seenStatuses})),
    );
    _loadStatuses();
  }

  Future<void> _showModerationNotice() async {
    final Map<String, dynamic>? notice;
    try {
      notice = await Api.takeModerationNotice();
    } catch (_) {
      return; // it stays unseen and comes up next time
    }
    if (notice == null || !mounted) return;
    final l = L.of(context);
    final reason = notice['reason'] as String?;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.t('messageRemoved')),
        content: Text(reason == null ? l.t('messageRemovedBody') : '${l.t('reasonLabel')}: $reason'),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(l.t('gotIt')))],
      ),
    );
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

  Widget _statusStrip() => StatusStrip(
    me: _me,
    mineCount: _myStatuses,
    groups: _statuses,
    seen: _seenStatuses,
    onMine: _openMyStatus,
    onOpen: _openStatus,
  );

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final convs = _convs;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.t('appName'), style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (_openReports != null)
            IconButton(
              tooltip: l.t('reports'),
              icon: Badge(
                isLabelVisible: _openReports! > 0,
                label: Text('$_openReports'),
                child: const Icon(Icons.flag_outlined),
              ),
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReportsPage()));
                _load();
              },
            ),
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
                        _statusStrip(),
                        const SizedBox(height: 160),
                        Text(l.t('noChats'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
                      ],
                    )
                  : ListView.builder(
                      itemCount: convs.length + 1,
                      itemBuilder: (_, index) {
                        if (index == 0) return _statusStrip();
                        final i = index - 1;
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

import 'dart:io';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models.dart';
import 'link_preview.dart';
import 'push.dart';

SupabaseClient get db => Supabase.instance.client;
String get myId => db.auth.currentUser!.id;

const maxUploadBytes = 50 * 1024 * 1024;

/// A search finds someone who isn't a friend only when it is the start of their
/// username and at most two letters short of it, so nobody can browse everyone.
bool usernameFound(String username, String query) {
  final q = query.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '').toLowerCase();
  final u = username.toLowerCase();
  return q.isNotEmpty && u.startsWith(q) && u.length - q.length <= 2;
}

class Api {
  static final Map<String, Profile> _profileCache = {};

  static Future<Profile?> profile(String id, {bool refresh = false}) async {
    if (!refresh && _profileCache.containsKey(id)) return _profileCache[id];
    final row = await db.from('profiles').select().eq('id', id).maybeSingle();
    if (row == null) return null;
    return _profileCache[id] = Profile.fromMap(row);
  }

  static void cacheProfile(Profile p) => _profileCache[p.id] = p;

  /// Strangers are found only by (nearly) their whole username, see [usernameFound].
  static Future<List<Profile>> searchUsers(String query) async {
    final q = query.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '').toLowerCase();
    if (q.isEmpty) return [];
    final rows = await db.from('profiles').select().ilike('username', '$q%').neq('id', myId).limit(50);
    // ilike treats "_" as a wildcard, so the exact check happens here.
    return rows.map(Profile.fromMap).where((p) => usernameFound(p.username, query)).toList();
  }

  /// Members of a conversation with their profiles.
  static Future<List<Profile>> members(String conversationId) async {
    final rows = await db.from('conversation_members').select('profiles(*)').eq('conversation_id', conversationId);
    final list = rows.map((r) => Profile.fromMap(r['profiles'] as Map<String, dynamic>)).toList();
    list.forEach(cacheProfile);
    return list;
  }

  /// For each of my DM conversations, the other person's profile.
  static Future<Map<String, Profile>> dmPeers() async {
    final rows = await db
        .from('conversation_members')
        .select('conversation_id, user_id, profiles(*), conversations!inner(is_group)')
        .neq('user_id', myId)
        .eq('conversations.is_group', false);
    final map = <String, Profile>{};
    for (final r in rows) {
      final p = Profile.fromMap(r['profiles'] as Map<String, dynamic>);
      cacheProfile(p);
      map[r['conversation_id'] as String] = p;
    }
    return map;
  }

  static Future<String> openDm(String otherId) async =>
      await db.rpc('get_or_create_dm', params: {'other': otherId}) as String;

  static Future<String> createGroup(String name, List<String> memberIds) async =>
      await db.rpc('create_group', params: {'group_name': name, 'member_ids': memberIds}) as String;

  static Future<void> addMembers(String conversationId, List<String> ids) => db
      .from('conversation_members')
      .insert(ids.map((id) => {'conversation_id': conversationId, 'user_id': id}).toList());

  static Future<void> leave(String conversationId) =>
      db.from('conversation_members').delete().eq('conversation_id', conversationId).eq('user_id', myId);

  static Future<String> upload(Uint8List bytes, String ext, String contentType) async {
    if (bytes.length > maxUploadBytes) throw const FileTooLarge();
    final path = '$myId/${const Uuid().v4()}.$ext';
    await db.storage.from('media').uploadBinary(path, bytes, fileOptions: FileOptions(contentType: contentType));
    return db.storage.from('media').getPublicUrl(path);
  }

  static Future<String> uploadFile(File file, String contentType) async {
    final ext = file.path.contains('.') ? file.path.split('.').last.toLowerCase() : 'bin';
    return upload(await file.readAsBytes(), ext, contentType);
  }

  static Future<Map<String, dynamic>> send(
    String conversationId, {
    required String type,
    String? content,
    String? mediaUrl,
    Map<String, dynamic> meta = const {},
  }) async {
    final row = await db
        .from('messages')
        .insert({
          'conversation_id': conversationId,
          'type': type,
          'content': content,
          'media_url': mediaUrl,
          'meta': meta,
        })
        .select()
        .single();
    if (type != 'call') Push.notify({'type': 'message', 'message_id': row['id']});
    return row;
  }

  /// Sends a text message, then attaches a preview card if it contains a link.
  static Future<void> sendText(String conversationId, String text, {Map<String, dynamic> meta = const {}}) async {
    final row = await send(conversationId, type: 'text', content: text, meta: meta);
    await _attachPreview(row['id'] as String, text, meta);
  }

  static Future<void> _attachPreview(String messageId, String text, Map<String, dynamic> meta) async {
    final url = LinkPreview.firstUrl(text);
    if (url == null) return;
    final preview = await LinkPreview.fetch(url);
    if (preview == null) return;
    await db
        .from('messages')
        .update({
          'meta': {...meta, 'preview': preview.toMap()},
        })
        .eq('id', messageId);
  }

  static Future<void> editMessage(Message m, String text) async {
    final meta = {...m.meta, 'edited': true}..remove('preview');
    await db.from('messages').update({'content': text, 'meta': meta}).eq('id', m.id);
    await _attachPreview(m.id, text, meta);
  }

  /// Sends a copy of [m] to another chat, without its reply quote or edit mark.
  static Future<void> forward(Message m, String conversationId) => send(
    conversationId,
    type: m.type,
    content: m.content,
    mediaUrl: m.mediaUrl,
    meta: {...m.meta}
      ..remove('reply')
      ..remove('edited'),
  );

  static Future<void> deleteMessage(String id) => db.from('messages').delete().eq('id', id);

  /// One reaction per person per message; picking the same emoji again removes it.
  static Future<void> react(Message m, String emoji, {String? current}) {
    if (current == emoji) {
      return db.from('reactions').delete().eq('message_id', m.id).eq('user_id', myId);
    }
    return db.from('reactions').upsert({
      'message_id': m.id,
      'conversation_id': m.conversationId,
      'user_id': myId,
      'emoji': emoji,
    }, onConflict: 'message_id,user_id');
  }

  // ───── Friends ─────

  static Future<List<Friendship>> friendships() async {
    final rows = await db
        .from('friendships')
        .select(
          'requester, addressee, status, req:profiles!friendships_requester_fkey(*), addr:profiles!friendships_addressee_fkey(*)',
        );
    return rows.map(Friendship.fromMap).toList();
  }

  static Future<int> pendingRequestCount() async {
    final rows = await db.from('friendships').select('requester').eq('addressee', myId).eq('status', 'pending');
    return rows.length;
  }

  static Future<void> requestFriend(String userId) async {
    await db.from('friendships').insert({'requester': myId, 'addressee': userId});
    Push.notify({'type': 'friend_request', 'to': userId});
  }

  static Future<void> acceptFriend(String requesterId) async {
    await db.from('friendships').update({'status': 'accepted'}).eq('requester', requesterId).eq('addressee', myId);
    Push.notify({'type': 'friend_accept', 'to': requesterId});
  }

  static Future<void> removeFriendship(Friendship f) =>
      db.from('friendships').delete().eq('requester', f.requesterId).eq('addressee', f.addresseeId);

  static Future<List<String>> savedStickers() async {
    final rows = await db
        .from('saved_stickers')
        .select('url')
        .eq('user_id', myId)
        .order('created_at', ascending: false);
    return rows.map((r) => r['url'] as String).toList();
  }

  static Future<void> saveSticker(String url) =>
      db.from('saved_stickers').upsert({'user_id': myId, 'url': url}, onConflict: 'user_id,url');

  static Future<void> removeSticker(String url) =>
      db.from('saved_stickers').delete().eq('user_id', myId).eq('url', url);
}

class FileTooLarge implements Exception {
  const FileTooLarge();
}

import 'dart:io';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models.dart';
import 'link_preview.dart';

SupabaseClient get db => Supabase.instance.client;
String get myId => db.auth.currentUser!.id;

const maxUploadBytes = 50 * 1024 * 1024;

class Api {
  static final Map<String, Profile> _profileCache = {};

  static Future<Profile?> profile(String id, {bool refresh = false}) async {
    if (!refresh && _profileCache.containsKey(id)) return _profileCache[id];
    final row = await db.from('profiles').select().eq('id', id).maybeSingle();
    if (row == null) return null;
    return _profileCache[id] = Profile.fromMap(row);
  }

  static void cacheProfile(Profile p) => _profileCache[p.id] = p;

  static Future<List<Profile>> searchUsers(String query) async {
    final q = query.replaceAll(RegExp(r'[,()%*\\]'), '').trim();
    final rows = await db
        .from('profiles')
        .select()
        .or('username.ilike.%$q%,display_name.ilike.%$q%')
        .neq('id', myId)
        .limit(30);
    return rows.map(Profile.fromMap).toList();
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
    return row;
  }

  /// Sends a text message, then attaches a preview card if it contains a link.
  static Future<void> sendText(String conversationId, String text, {Map<String, dynamic> meta = const {}}) async {
    final row = await send(conversationId, type: 'text', content: text, meta: meta);
    final url = LinkPreview.firstUrl(text);
    if (url == null) return;
    final preview = await LinkPreview.fetch(url);
    if (preview == null) return;
    await db
        .from('messages')
        .update({
          'meta': {...meta, 'preview': preview.toMap()},
        })
        .eq('id', row['id']);
  }

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

  static Future<void> requestFriend(String userId) =>
      db.from('friendships').insert({'requester': myId, 'addressee': userId});

  static Future<void> acceptFriend(String requesterId) =>
      db.from('friendships').update({'status': 'accepted'}).eq('requester', requesterId).eq('addressee', myId);

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

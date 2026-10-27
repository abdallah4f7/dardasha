class Profile {
  Profile({required this.id, required this.username, required this.displayName, this.avatarUrl});

  final String id;
  final String username;
  final String displayName;
  final String? avatarUrl;

  factory Profile.fromMap(Map<String, dynamic> m) => Profile(
    id: m['id'] as String,
    username: m['username'] as String? ?? '',
    displayName: m['display_name'] as String? ?? m['username'] as String? ?? '',
    avatarUrl: m['avatar_url'] as String?,
  );
}

class Conversation {
  Conversation({
    required this.id,
    required this.isGroup,
    this.name,
    this.avatarUrl,
    this.lastMessageText,
    this.lastMessageType,
    required this.lastMessageAt,
  });

  final String id;
  final bool isGroup;
  final String? name;
  final String? avatarUrl;
  final String? lastMessageText;
  final String? lastMessageType;
  final DateTime lastMessageAt;

  factory Conversation.fromMap(Map<String, dynamic> m) => Conversation(
    id: m['id'] as String,
    isGroup: m['is_group'] as bool? ?? false,
    name: m['name'] as String?,
    avatarUrl: m['avatar_url'] as String?,
    lastMessageText: m['last_message_text'] as String?,
    lastMessageType: m['last_message_type'] as String?,
    lastMessageAt: DateTime.parse(m['last_message_at'] as String).toLocal(),
  );
}

class Friendship {
  Friendship({
    required this.requesterId,
    required this.addresseeId,
    required this.accepted,
    required this.requester,
    required this.addressee,
  });

  final String requesterId;
  final String addresseeId;
  final bool accepted;
  final Profile requester;
  final Profile addressee;

  /// The other person, seen from [me].
  Profile other(String me) => requesterId == me ? addressee : requester;
  bool incoming(String me) => !accepted && addresseeId == me;

  factory Friendship.fromMap(Map<String, dynamic> m) => Friendship(
    requesterId: m['requester'] as String,
    addresseeId: m['addressee'] as String,
    accepted: m['status'] == 'accepted',
    requester: Profile.fromMap(m['req'] as Map<String, dynamic>),
    addressee: Profile.fromMap(m['addr'] as Map<String, dynamic>),
  );
}

class Reaction {
  Reaction({required this.messageId, required this.userId, required this.emoji});

  final String messageId;
  final String userId;
  final String emoji;

  factory Reaction.fromMap(Map<String, dynamic> m) =>
      Reaction(messageId: m['message_id'] as String, userId: m['user_id'] as String, emoji: m['emoji'] as String);
}

class Message {
  Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.type,
    this.content,
    this.mediaUrl,
    required this.meta,
    required this.createdAt,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final String type; // text | image | video | voice | sticker | call
  final String? content;
  final String? mediaUrl;
  final Map<String, dynamic> meta;
  final DateTime createdAt;

  factory Message.fromMap(Map<String, dynamic> m) => Message(
    id: m['id'] as String,
    conversationId: m['conversation_id'] as String,
    senderId: m['sender_id'] as String,
    type: m['type'] as String? ?? 'text',
    content: m['content'] as String?,
    mediaUrl: m['media_url'] as String?,
    meta: Map<String, dynamic>.from(m['meta'] as Map? ?? {}),
    createdAt: DateTime.parse(m['created_at'] as String).toLocal(),
  );
}

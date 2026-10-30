import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:device_state/device_state.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../pages/chat_page.dart';
import '../pages/friends_page.dart';
import 'api.dart';
import 'calls.dart';

const _callNotificationId = 7;
const _flagInsistent = 4; // Android Notification.FLAG_INSISTENT: keep ringing

// Android fixes a channel's sound when it is created, so Dardasha's own tones got new channel ids.
const _messagesChannel = 'messages_v2';
const _callsChannel = 'calls_v2';
const _messageSound = RawResourceAndroidNotificationSound('dardasha_message');
const _ringSound = RawResourceAndroidNotificationSound('dardasha_ring');

/// Runs in its own isolate when a push arrives while the app is closed or in the background.
/// Message pushes are shown by Android itself; calls are data-only so they can ring.
@pragma('vm:entry-point')
Future<void> _onBackgroundPush(RemoteMessage m) async {
  switch (m.data['type']) {
    case 'call':
      await Push._initLocal();
      await Push._showCall(m.data);
    case 'call_end':
      await Push._initLocal();
      await Push.cancelCall();
  }
}

/// "Decline" on the call notification, handled without opening the app: tells
/// the caller, and this phone's own app in case it is running in the background.
@pragma('vm:entry-point')
Future<void> _onBackgroundAction(NotificationResponse r) async {
  if (r.actionId != 'decline') return;
  final d = Push._decode(r.payload);
  final callId = d['call_id'], from = d['from'], to = d['to'];
  if (callId == null || from == null || to == null) return;
  Map<String, dynamic> reject(String topic, String target, String sender) => {
    'topic': 'calls:$topic',
    'event': 'signal',
    'payload': {
      'data': {'type': 'reject', 'callId': callId, 'to': target, 'from': sender},
    },
  };
  try {
    await http.post(
      Uri.parse('$supabaseUrl/realtime/v1/api/broadcast'),
      headers: {'apikey': supabasePublishableKey, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'messages': [reject(from, from, to), reject(to, to, from)],
      }),
    );
  } catch (_) {}
}

/// Push notifications through Firebase Cloud Messaging. The `push` Supabase
/// function decides who gets notified and sends them; the app only registers
/// its token, asks the function to notify, and displays/opens notifications.
class Push {
  static final _local = FlutterLocalNotificationsPlugin();
  static late GlobalKey<NavigatorState> _navigatorKey;
  static bool _ready = false;
  static bool _handledLaunch = false;
  static StreamSubscription<String>? _tokenSub;

  /// The chat on screen right now; its messages don't need a notification.
  static String? openConversation;

  static bool get _isAr => Platform.localeName.toLowerCase().startsWith('ar');

  static Future<void> init(GlobalKey<NavigatorState> navigatorKey) async {
    _navigatorKey = navigatorKey;
    if (firebaseOptions == null || kIsWeb || !Platform.isAndroid) return;
    try {
      await Firebase.initializeApp(options: firebaseOptions);
      FirebaseMessaging.onBackgroundMessage(_onBackgroundPush);
      await _initLocal(onTap: (r) => _open(_decode(r.payload), action: r.actionId));
      FirebaseMessaging.onMessage.listen(_onForeground);
      FirebaseMessaging.onMessageOpenedApp.listen((m) => _open(m.data));
      _ready = true;
    } catch (_) {}
  }

  static Future<void> _initLocal({DidReceiveNotificationResponseCallback? onTap}) async {
    await _local.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('ic_notification')),
      onDidReceiveNotificationResponse: onTap,
      onDidReceiveBackgroundNotificationResponse: _onBackgroundAction,
    );
    final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    for (final old in const ['messages', 'calls']) {
      await android?.deleteNotificationChannel(channelId: old);
    }
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        _messagesChannel,
        _isAr ? 'الرسائل' : 'Messages',
        importance: Importance.high,
        sound: _messageSound,
      ),
    );
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        _callsChannel,
        _isAr ? 'المكالمات' : 'Calls',
        importance: Importance.max,
        sound: _ringSound,
        audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
      ),
    );
  }

  /// After sign-in: ask for permission and save this device's token.
  static Future<void> register() async {
    if (!_ready) return;
    try {
      await _local
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      final fm = FirebaseMessaging.instance;
      final token = await fm.getToken();
      if (token != null) await _save(token);
      _tokenSub ??= fm.onTokenRefresh.listen(_save);

      if (_handledLaunch) return;
      _handledLaunch = true;
      final initial = await fm.getInitialMessage();
      if (initial != null) return _open(initial.data);
      final launch = await _local.getNotificationAppLaunchDetails();
      final r = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true) _open(_decode(r?.payload), action: r?.actionId);
    } catch (_) {}
  }

  static Future<void> _save(String token) =>
      db.rpc('register_push_token', params: {'t': token, 'l': _isAr ? 'ar' : 'en'});

  /// Before sign-out, so this phone stops getting the account's notifications.
  static Future<void> unregister() async {
    if (!_ready) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await db.from('push_tokens').delete().eq('token', token);
    } catch (_) {}
  }

  /// Asks the server to notify the people concerned. Fire-and-forget.
  static void notify(Map<String, dynamic> body) {
    unawaited(db.functions.invoke('push', body: body).then((_) {}, onError: (_) {}));
  }

  static Future<void> _onForeground(RemoteMessage m) async {
    final d = m.data;
    final n = m.notification;
    if (n == null) return; // calls: the app is open, the call screen shows itself
    final convId = d['conversation_id'] as String?;
    if (convId != null && convId == openConversation) return;
    await _local.show(
      id: 0,
      title: n.title,
      body: n.body,
      payload: jsonEncode(d),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _messagesChannel,
          _isAr ? 'الرسائل' : 'Messages',
          importance: Importance.high,
          sound: _messageSound,
          priority: Priority.high,
          icon: 'ic_notification',
          tag: convId ?? d['type'] as String?,
        ),
      ),
    );
  }

  /// While the phone is in use the call shows as a notification with answer and
  /// decline buttons; with the screen off or locked it opens the ringing screen.
  static Future<void> _showCall(Map<String, dynamic> d) async {
    final video = d['video'] == 'true';
    final inUse = await phoneInUse();
    final body = _isAr
        ? (video ? 'مكالمة فيديو واردة' : 'مكالمة صوتية واردة')
        : (video ? 'Incoming video call' : 'Incoming voice call');
    await _local.show(
      id: _callNotificationId,
      title: d['from_name'] as String?,
      body: body,
      payload: jsonEncode({'type': 'call', 'call_id': d['call_id'], 'from': d['caller'], 'to': d['callee']}),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _callsChannel,
          _isAr ? 'المكالمات' : 'Calls',
          importance: Importance.max,
          sound: _ringSound,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: !inUse,
          ongoing: true,
          timeoutAfter: 45000,
          icon: 'ic_notification',
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
          additionalFlags: Int32List.fromList([_flagInsistent]),
          actions: [
            AndroidNotificationAction(
              'decline',
              _isAr ? 'رفض' : 'Decline',
              titleColor: const Color(0xFFE53935),
              cancelNotification: true,
            ),
            AndroidNotificationAction(
              'accept',
              _isAr ? 'رد' : 'Answer',
              titleColor: const Color(0xFF43A047),
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> cancelCall() async {
    try {
      await _local.cancel(id: _callNotificationId);
    } catch (_) {}
  }

  /// Removes a chat's notifications once it is opened. Pushes shown by Android
  /// and by [_onForeground] both use id 0 tagged with the conversation.
  static Future<void> clearConversation(String conversationId) async {
    try {
      await _local.cancel(id: 0, tag: conversationId);
    } catch (_) {}
  }

  static Map<String, dynamic> _decode(String? payload) {
    if (payload == null) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(payload) as Map);
    } catch (_) {
      return {};
    }
  }

  static void _open(Map<String, dynamic> d, {String? action}) {
    final nav = _navigatorKey.currentState;
    if (nav == null) return;
    switch (d['type']) {
      case 'call':
        // The ringing screen comes with the caller's next offer; "Answer" picks it up right away.
        final callId = d['call_id'] as String?;
        if (action == 'accept' && callId != null) CallService.instance.answerWhenReady(callId);
      case 'message':
        final convId = d['conversation_id'] as String?;
        if (convId == null || convId == openConversation) return;
        nav.push(
          MaterialPageRoute(
            builder: (_) => ChatPage(
              conversationId: convId,
              isGroup: d['is_group'] == 'true',
              title: d['chat_title'] as String? ?? '',
            ),
          ),
        );
      case 'friend_request':
        nav.push(MaterialPageRoute(builder: (_) => const FriendsPage(initialTab: 1)));
      case 'friend_accept':
        nav.push(MaterialPageRoute(builder: (_) => const FriendsPage()));
    }
  }
}

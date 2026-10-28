import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../config.dart';
import '../pages/chat_page.dart';
import '../pages/friends_page.dart';
import 'api.dart';

const _callNotificationId = 7;
const _flagInsistent = 4; // Android Notification.FLAG_INSISTENT: keep ringing

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
    if (firebaseOptions == null || !Platform.isAndroid) return;
    try {
      await Firebase.initializeApp(options: firebaseOptions);
      FirebaseMessaging.onBackgroundMessage(_onBackgroundPush);
      await _initLocal(onTap: (r) => _open(_decode(r.payload)));
      FirebaseMessaging.onMessage.listen(_onForeground);
      FirebaseMessaging.onMessageOpenedApp.listen((m) => _open(m.data));
      _ready = true;
    } catch (_) {}
  }

  static Future<void> _initLocal({DidReceiveNotificationResponseCallback? onTap}) async {
    await _local.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('ic_notification')),
      onDidReceiveNotificationResponse: onTap,
    );
    final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      AndroidNotificationChannel('messages', _isAr ? 'الرسائل' : 'Messages', importance: Importance.high),
    );
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        'calls',
        _isAr ? 'المكالمات' : 'Calls',
        importance: Importance.max,
        sound: const UriAndroidNotificationSound('content://settings/system/ringtone'),
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
      if (launch?.didNotificationLaunchApp == true) _open(_decode(launch!.notificationResponse?.payload));
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
          'messages',
          _isAr ? 'الرسائل' : 'Messages',
          importance: Importance.high,
          priority: Priority.high,
          icon: 'ic_notification',
          tag: convId ?? d['type'] as String?,
        ),
      ),
    );
  }

  static Future<void> _showCall(Map<String, dynamic> d) async {
    final video = d['video'] == 'true';
    final body = _isAr
        ? (video ? 'مكالمة فيديو واردة' : 'مكالمة صوتية واردة')
        : (video ? 'Incoming video call' : 'Incoming voice call');
    await _local.show(
      id: _callNotificationId,
      title: d['from_name'] as String?,
      body: body,
      payload: jsonEncode({'type': 'call'}),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'calls',
          _isAr ? 'المكالمات' : 'Calls',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: true,
          ongoing: true,
          timeoutAfter: 45000,
          icon: 'ic_notification',
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
          additionalFlags: Int32List.fromList([_flagInsistent]),
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

  static void _open(Map<String, dynamic> d) {
    final nav = _navigatorKey.currentState;
    if (nav == null) return;
    switch (d['type']) {
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

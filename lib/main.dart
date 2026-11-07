import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'l10n.dart';
import 'models.dart';
import 'pages/auth_page.dart';
import 'pages/banned_page.dart';
import 'pages/complete_profile_page.dart';
import 'pages/home_page.dart';
import 'services/api.dart';
import 'services/calls.dart';
import 'services/moderation.dart';
import 'services/push.dart';

final navigatorKey = GlobalKey<NavigatorState>();

const brand = Color(0xFF4F6BED);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Right-click opens our message menu, not the browser's.
  if (kIsWeb) await BrowserContextMenu.disableContextMenu();
  await Supabase.initialize(url: supabaseUrl, publishableKey: supabasePublishableKey);
  CallService.instance.navigatorKey = navigatorKey;
  Moderation.navigatorKey = navigatorKey;
  await Push.init(navigatorKey);
  runApp(const ChatApp());
}

ThemeData _theme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: brand, brightness: b);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: .6),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    ),
  );
}

class ChatApp extends StatelessWidget {
  const ChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (c) => L.of(c).t('appName'),
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ar'), Locale('en')],
      localeResolutionCallback: (locale, _) => locale?.languageCode == 'ar' ? const Locale('ar') : const Locale('en'),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

enum _Stage { loading, auth, setupProfile, home, banned }

/// Signed out → login/sign-up. Signed in without a profile → profile setup,
/// unless the account was just created by "Log in with …", which goes back to sign-up.
class _AuthGateState extends State<AuthGate> {
  late final StreamSubscription<AuthState> _sub;
  _Stage _stage = _Stage.loading;
  String? _userId;
  bool _startOnRegister = false;
  String? _notice;
  int _run = 0;
  Ban? _ban;
  RealtimeChannel? _banWatch;

  @override
  void initState() {
    super.initState();
    _evaluate();
    _sub = db.auth.onAuthStateChange.listen((e) {
      final id = e.session?.user.id;
      if (id != _userId) _evaluate();
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    if (_banWatch != null) db.removeChannel(_banWatch!);
    super.dispose();
  }

  /// A ban takes effect right away, even with the app open.
  void _watchBan(String? userId) {
    if (_banWatch != null) db.removeChannel(_banWatch!);
    _banWatch = null;
    if (userId == null) return;
    _banWatch = db
        .channel('ban:$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'bans',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: userId),
          callback: (_) => _evaluate(),
        )
        .subscribe();
  }

  Future<void> _evaluate() async {
    final run = ++_run;
    final user = db.auth.currentUser;
    if (user?.id != _userId || _banWatch == null) _watchBan(user?.id);
    _userId = user?.id;
    if (user == null) {
      CallService.instance.stop();
      setState(() => _stage = _Stage.auth);
      return;
    }
    setState(() => _stage = _Stage.loading);

    Profile? profile;
    var failed = false;
    Ban? ban;
    try {
      profile = await Api.profile(user.id, refresh: true);
      ban = await Api.myBan();
    } catch (_) {
      failed = true; // offline: let them in, the app retries its own loads
    }
    if (run != _run || !mounted) return;

    final prefs = await SharedPreferences.getInstance();
    final intent = prefs.getString(authIntentKey);
    await prefs.remove(authIntentKey);

    if (ban != null) {
      CallService.instance.stop();
      setState(() {
        _ban = ban;
        _stage = _Stage.banned;
      });
    } else if (profile != null || failed) {
      CallService.instance.start();
      Push.register();
      setState(() => _stage = _Stage.home);
    } else if (intent == 'oauth_login') {
      _startOnRegister = true;
      _notice = 'noAccountForEmail';
      await db.auth.signOut();
    } else {
      setState(() => _stage = _Stage.setupProfile);
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.loading:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case _Stage.auth:
        final page = AuthPage(key: ValueKey(_notice), startOnRegister: _startOnRegister, notice: _notice);
        _startOnRegister = false;
        _notice = null;
        return page;
      case _Stage.setupProfile:
        return CompleteProfilePage(onDone: _evaluate);
      case _Stage.home:
        return const HomePage();
      case _Stage.banned:
        return BannedPage(ban: _ban!, onRetry: _evaluate);
    }
  }
}

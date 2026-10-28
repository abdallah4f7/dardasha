import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'l10n.dart';
import 'models.dart';
import 'pages/auth_page.dart';
import 'pages/complete_profile_page.dart';
import 'pages/home_page.dart';
import 'services/api.dart';
import 'services/calls.dart';
import 'services/push.dart';

final navigatorKey = GlobalKey<NavigatorState>();

const brand = Color(0xFF4F6BED);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, publishableKey: supabasePublishableKey);
  CallService.instance.navigatorKey = navigatorKey;
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

enum _Stage { loading, auth, setupProfile, home }

/// Signed out → login/sign-up. Signed in without a profile → profile setup,
/// unless the account was just created by "Log in with …", which goes back to sign-up.
class _AuthGateState extends State<AuthGate> {
  late final StreamSubscription<AuthState> _sub;
  _Stage _stage = _Stage.loading;
  String? _userId;
  bool _startOnRegister = false;
  String? _notice;
  int _run = 0;

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
    super.dispose();
  }

  Future<void> _evaluate() async {
    final run = ++_run;
    final user = db.auth.currentUser;
    _userId = user?.id;
    if (user == null) {
      CallService.instance.stop();
      setState(() => _stage = _Stage.auth);
      return;
    }
    setState(() => _stage = _Stage.loading);

    Profile? profile;
    var failed = false;
    try {
      profile = await Api.profile(user.id, refresh: true);
    } catch (_) {
      failed = true; // offline: let them in, the app retries its own loads
    }
    if (run != _run || !mounted) return;

    final prefs = await SharedPreferences.getInstance();
    final intent = prefs.getString(authIntentKey);
    await prefs.remove(authIntentKey);

    if (profile != null || failed) {
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
    }
  }
}

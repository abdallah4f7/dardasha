import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../l10n.dart';
import '../services/api.dart';
import '../widgets/common.dart';

/// Where the OAuth browser flow returns to. Must also be listed in
/// Supabase → Authentication → URL Configuration → Redirect URLs.
const authRedirect = 'com.dardasha.chat://login-callback';

/// Remembered across the browser round-trip so the app knows whether a brand-new
/// OAuth account came from "Log in" (→ send to sign-up) or "Create account" (→ set up profile).
const authIntentKey = 'auth_intent';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, this.startOnRegister = false, this.notice});

  final bool startOnRegister;
  final String? notice;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  late bool _register = widget.startOnRegister;
  bool _busy = false;
  Set<String> _providers = {};

  @override
  void initState() {
    super.initState();
    _loadProviders();
    if (widget.notice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) toast(context, L.of(context).t(widget.notice!));
      });
    }
  }

  /// Only show the Google button when it is switched on in Supabase.
  Future<void> _loadProviders() async {
    try {
      final r = await http
          .get(Uri.parse('$supabaseUrl/auth/v1/settings'), headers: {'apikey': supabasePublishableKey})
          .timeout(const Duration(seconds: 8));
      final external = (jsonDecode(r.body) as Map<String, dynamic>)['external'] as Map<String, dynamic>? ?? {};
      final on = {
        for (final p in ['google'])
          if (external[p] == true) p,
      };
      if (mounted) setState(() => _providers = on);
    } catch (_) {}
  }

  Future<void> _setIntent(String intent) async =>
      (await SharedPreferences.getInstance()).setString(authIntentKey, intent);

  Future<void> _oauth(OAuthProvider provider) async {
    setState(() => _busy = true);
    try {
      await _setIntent(_register ? 'oauth_register' : 'oauth_login');
      await db.auth.signInWithOAuth(provider, redirectTo: authRedirect);
    } on AuthException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final l = L.of(context);
    setState(() => _busy = true);
    try {
      await _setIntent(_register ? 'email_register' : 'email_login');
      if (_register) {
        final res = await db.auth.signUp(email: _email.text.trim(), password: _password.text);
        if (res.session == null && mounted) toast(context, l.t('confirmEmail'));
      } else {
        await db.auth.signInWithPassword(email: _email.text.trim(), password: _password.text);
      }
    } on AuthException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: Image.asset(
                          'assets/icon/icon.png',
                          height: 84,
                          errorBuilder: (_, _, _) {
                            return Icon(Icons.forum_rounded, size: 84, color: scheme.primary);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l.t('appName'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _register ? l.t('register') : l.t('login'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 28),
                    if (_providers.contains('google')) ...[
                      _SocialButton(
                        label: '${l.t('continueWith')} Google',
                        icon: const _GoogleLogo(),
                        background: Colors.white,
                        foreground: Colors.black87,
                        border: dark ? null : scheme.outlineVariant,
                        onPressed: _busy ? null : () => _oauth(OAuthProvider.google),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (_providers.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Expanded(child: Divider()),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(l.t('or'), style: TextStyle(color: scheme.onSurfaceVariant)),
                          ),
                          const Expanded(child: Divider()),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textDirection: TextDirection.ltr,
                      decoration: InputDecoration(
                        labelText: l.t('email'),
                        prefixIcon: const Icon(Icons.alternate_email),
                      ),
                      validator: (v) => (v == null || !v.contains('@')) ? l.t('required') : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      autofillHints: [_register ? AutofillHints.newPassword : AutofillHints.password],
                      textDirection: TextDirection.ltr,
                      decoration: InputDecoration(
                        labelText: l.t('password'),
                        prefixIcon: const Icon(Icons.lock_outline),
                      ),
                      validator: (v) => (v ?? '').length < 6 ? '≥ 6' : null,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      child: _busy
                          ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                          : Text(_register ? l.t('register') : l.t('login')),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: () => setState(() => _register = !_register),
                      child: Text(_register ? l.t('haveAccount') : l.t('noAccount')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SocialButton extends StatelessWidget {
  const _SocialButton({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.onPressed,
    this.border,
  });

  final String label;
  final Widget icon;
  final Color background;
  final Color foreground;
  final Color? border;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        backgroundColor: background,
        foregroundColor: foreground,
        side: BorderSide(color: border ?? background),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      ),
      child: Row(
        children: [
          SizedBox(width: 28, child: Center(child: icon)),
          Expanded(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 28),
        ],
      ),
    );
  }
}

/// Four-colour "G" drawn with arcs, so no image asset is needed.
class _GoogleLogo extends StatelessWidget {
  const _GoogleLogo();

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size.square(22), painter: _GooglePainter());
}

class _GooglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width * .2;
    final rect = Rect.fromLTWH(w / 2, w / 2, size.width - w, size.height - w);
    Paint p(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w;
    const deg = 3.1415926535 / 180;
    canvas.drawArc(rect, -40 * deg, -100 * deg, false, p(const Color(0xFFEA4335)));
    canvas.drawArc(rect, -140 * deg, -90 * deg, false, p(const Color(0xFFFBBC05)));
    canvas.drawArc(rect, -230 * deg, -95 * deg, false, p(const Color(0xFF34A853)));
    canvas.drawArc(rect, -325 * deg, -35 * deg, false, p(const Color(0xFF4285F4)));
    canvas.drawRect(
      Rect.fromLTWH(size.width / 2, size.height / 2 - w / 2, size.width / 2, w),
      Paint()..color = const Color(0xFF4285F4),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';

/// Shown once after sign-up (any method): choose a username and display name.
class CompleteProfilePage extends StatefulWidget {
  const CompleteProfilePage({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<CompleteProfilePage> createState() => _CompleteProfilePageState();
}

class _CompleteProfilePageState extends State<CompleteProfilePage> {
  final _form = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _name = TextEditingController();
  String? _avatarUrl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Prefill from Google / Apple when available.
    final meta = db.auth.currentUser?.userMetadata ?? {};
    _name.text = (meta['full_name'] ?? meta['name'] ?? meta['global_name'] ?? '') as String;
    _avatarUrl = (meta['avatar_url'] ?? meta['picture']) as String?;
    final suggestion = ((meta['preferred_username'] ?? meta['user_name'] ?? '') as String).toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9_]'),
      '',
    );
    if (suggestion.length >= 3) _username.text = suggestion.substring(0, suggestion.length.clamp(3, 20));
  }

  Future<void> _pickPhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 512, imageQuality: 85);
    if (x == null) return;
    setState(() => _busy = true);
    try {
      final url = await Api.upload(await x.readAsBytes(), 'jpg', 'image/jpeg');
      setState(() => _avatarUrl = url);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final l = L.of(context);
    final username = _username.text.trim().toLowerCase();
    setState(() => _busy = true);
    try {
      final free = await db.rpc('username_available', params: {'name': username}) as bool;
      if (!free) {
        if (mounted) toast(context, l.t('usernameTaken'));
        return;
      }
      final row = await db
          .from('profiles')
          .insert({
            'id': myId,
            'username': username,
            'display_name': _name.text.trim().isEmpty ? username : _name.text.trim(),
            'avatar_url': _avatarUrl,
          })
          .select()
          .single();
      Api.cacheProfile(Profile.fromMap(row));
      widget.onDone();
    } on PostgrestException catch (e) {
      if (mounted) toast(context, e.code == '23505' ? l.t('usernameTaken') : e.message);
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
    return Scaffold(
      appBar: AppBar(
        actions: [TextButton(onPressed: () => db.auth.signOut(), child: Text(l.t('logout')))],
      ),
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
                    Text(
                      l.t('completeProfile'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l.t('completeProfileHint'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 28),
                    Center(
                      child: GestureDetector(
                        onTap: _busy ? null : _pickPhoto,
                        child: Stack(
                          children: [
                            Avatar(name: _name.text.isEmpty ? _username.text : _name.text, url: _avatarUrl, radius: 52),
                            PositionedDirectional(
                              end: 0,
                              bottom: 0,
                              child: CircleAvatar(
                                radius: 17,
                                backgroundColor: scheme.primary,
                                child: Icon(Icons.camera_alt, size: 17, color: scheme.onPrimary),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    TextFormField(
                      controller: _username,
                      textDirection: TextDirection.ltr,
                      decoration: InputDecoration(labelText: l.t('username'), prefixText: '@'),
                      validator: (v) =>
                          RegExp(r'^[a-zA-Z0-9_]{3,20}$').hasMatch(v?.trim() ?? '') ? null : l.t('usernameInvalid'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _name,
                      maxLength: 40,
                      decoration: InputDecoration(labelText: l.t('displayName')),
                      onChanged: (_) => setState(() {}),
                      validator: (v) => (v ?? '').trim().isEmpty ? l.t('required') : null,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _busy ? null : _save,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      child: _busy
                          ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                          : Text(l.t('continue')),
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

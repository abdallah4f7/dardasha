import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import '../services/push.dart';
import '../widgets/avatar.dart';
import '../widgets/common.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _name = TextEditingController();
  Profile? _me;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Api.profile(myId).then((p) {
      if (!mounted || p == null) return;
      setState(() => _me = p);
      _name.text = p.displayName;
    });
  }

  Future<void> _save({String? avatarUrl}) async {
    setState(() => _busy = true);
    try {
      final row = await db
          .from('profiles')
          .update({
            'display_name': _name.text.trim().isEmpty ? _me!.username : _name.text.trim(),
            'avatar_url': ?avatarUrl,
          })
          .eq('id', myId)
          .select()
          .single();
      final p = Profile.fromMap(row);
      Api.cacheProfile(p);
      if (mounted) setState(() => _me = p);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 512, imageQuality: 85);
    if (x == null) return;
    setState(() => _busy = true);
    try {
      final url = await Api.upload(await x.readAsBytes(), 'jpg', 'image/jpeg');
      await _save(avatarUrl: url);
    } catch (e) {
      if (mounted) showError(context, e);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final me = _me;
    return Scaffold(
      appBar: AppBar(title: Text(l.t('profile'))),
      body: me == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (_busy) const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Center(
                  child: GestureDetector(
                    onTap: _busy ? null : _changePhoto,
                    child: Stack(
                      children: [
                        Avatar(name: me.displayName, url: me.avatarUrl, radius: 56),
                        PositionedDirectional(
                          end: 0,
                          bottom: 0,
                          child: CircleAvatar(
                            radius: 18,
                            backgroundColor: Theme.of(context).colorScheme.primary,
                            child: const Icon(Icons.camera_alt, size: 18, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(child: Text('@${me.username}', textDirection: TextDirection.ltr)),
                const SizedBox(height: 24),
                TextField(
                  controller: _name,
                  decoration: InputDecoration(labelText: l.t('displayName')),
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 12),
                FilledButton(onPressed: _busy ? null : _save, child: Text(l.t('save'))),
                const SizedBox(height: 40),
                OutlinedButton.icon(
                  icon: const Icon(Icons.logout),
                  label: Text(l.t('logout')),
                  style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                  onPressed: () async {
                    Navigator.of(context).popUntil((r) => r.isFirst);
                    await Push.unregister();
                    await db.auth.signOut();
                  },
                ),
              ],
            ),
    );
  }
}

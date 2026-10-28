import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n.dart';
import '../widgets/common.dart';

/// New versions are published as GitHub releases with the APK attached.
/// On launch, offer the latest one if it is newer than this build.
class Updater {
  static const _latest = 'https://api.github.com/repos/abdallah4f7/dardasha/releases/latest';
  static bool _checked = false;

  static Future<void> check(BuildContext context) async {
    if (_checked || !Platform.isAndroid) return;
    _checked = true;
    try {
      final res = await http.get(Uri.parse(_latest), headers: {'Accept': 'application/vnd.github+json'});
      if (res.statusCode != 200) return;
      final release = jsonDecode(res.body) as Map<String, dynamic>;
      final version = (release['tag_name'] as String? ?? '').replaceFirst(RegExp('^v'), '');
      final info = await PackageInfo.fromPlatform();
      if (!_isNewer(version, info.version)) return;
      final apk = (release['assets'] as List? ?? [])
          .cast<Map<String, dynamic>>()
          .where((a) => (a['name'] as String).endsWith('.apk'))
          .firstOrNull;
      if (apk == null || !context.mounted) return;

      final l = L.of(context);
      final notes = (release['body'] as String? ?? '').trim();
      final go = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.system_update),
          title: Text('${l.t('updateAvailable')} $version'),
          content: notes.isEmpty ? null : SingleChildScrollView(child: Text(notes)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.t('later'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(l.t('update'))),
          ],
        ),
      );
      if (go == true && context.mounted) await _install(context, apk['browser_download_url'] as String, version);
    } catch (_) {}
  }

  static bool _isNewer(String latest, String current) {
    List<int> parts(String v) => v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final a = parts(latest), b = parts(current);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  static Future<void> _install(BuildContext context, String url, String version) async {
    final l = L.of(context);
    final progress = ValueNotifier<double?>(null);
    final nav = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(l.t('downloadingUpdate')),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, p, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: p),
                const SizedBox(height: 12),
                Text(p == null ? '' : '${(p * 100).round()}%'),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      final client = http.Client();
      final res = await client.send(http.Request('GET', Uri.parse(url)));
      if (res.statusCode != 200) throw HttpException('${res.statusCode}');
      final file = File('${(await getTemporaryDirectory()).path}/Dardasha-$version.apk');
      final sink = file.openWrite();
      final total = res.contentLength ?? 0;
      var got = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) progress.value = got / total;
      }
      await sink.close();
      client.close();
      nav.pop();
      final result = await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
      if (result.type != ResultType.done && context.mounted) toast(context, l.t('updateFailed'));
    } catch (_) {
      nav.pop();
      if (context.mounted) toast(context, l.t('updateFailed'));
    }
  }
}

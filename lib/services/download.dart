import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n.dart';
import '../models.dart';
import '../widgets/common.dart';

/// Photos, videos and stickers go to the gallery; voice messages open the share
/// sheet so they can be saved to Files / Drive or sent elsewhere.
/// Files open in whatever app the phone has for them (the browser downloads them).
Future<void> openFile(BuildContext context, Message m) async {
  final url = m.mediaUrl;
  if (url == null) return;
  final name = m.content ?? 'file';
  final type = contentTypeFor(name);
  if (kIsWeb) {
    // Supabase sends it as an attachment under its original name.
    await launchUrl(Uri.parse('$url?download=${Uri.encodeComponent(name)}'), webOnlyWindowName: '_blank');
    return;
  }
  final dir = Directory('${(await getTemporaryDirectory()).path}/files/${m.id}');
  final file = File('${dir.path}/${name.replaceAll(RegExp(r'[/\\]'), '_')}');
  if (!await file.exists()) {
    if (context.mounted) toast(context, '${L.of(context).t('download')}…');
    final res = await http.get(Uri.parse(url));
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    await dir.create(recursive: true);
    await file.writeAsBytes(res.bodyBytes);
  }
  final result = await OpenFilex.open(file.path, type: type);
  // No app for this kind of file: let them send it somewhere that can.
  if (result.type != ResultType.done) {
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: type)]));
  }
}

Future<void> downloadMessage(BuildContext context, Message m) async {
  if (m.type == 'file') return openFile(context, m);
  final url = m.mediaUrl;
  if (url == null) return;
  if (kIsWeb) {
    await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank'); // the browser saves it
    return;
  }
  final l = L.of(context);
  toast(context, '${l.t('download')}…');

  final res = await http.get(Uri.parse(url));
  if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
  final path = Uri.parse(url).path;
  final ext = path.contains('.') ? path.split('.').last : 'bin';
  final file = File('${(await getTemporaryDirectory()).path}/chat_${m.id}.$ext');
  await file.writeAsBytes(res.bodyBytes);

  if (m.type == 'voice') {
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: 'audio/mp4')]));
    return;
  }
  if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
  if (m.type == 'video') {
    await Gal.putVideo(file.path, album: l.t('appName'));
  } else {
    await Gal.putImage(file.path, album: l.t('appName'));
  }
  if (context.mounted) toast(context, l.t('savedToGallery'));
}

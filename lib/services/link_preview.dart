import 'dart:convert';

import 'package:http/http.dart' as http;

/// Thumbnail + title for a shared link, and how to play it inside the app.
class LinkPreview {
  LinkPreview({required this.url, this.title, this.image, this.site, required this.kind, this.videoId});

  final String url;
  final String? title;
  final String? image;
  final String? site;
  final String kind; // youtube | tiktok | snapchat | instagram | x | web
  final String? videoId;

  bool get isVideo => kind != 'web';

  Map<String, dynamic> toMap() => {
    'url': url,
    'title': title,
    'image': image,
    'site': site,
    'kind': kind,
    'videoId': videoId,
  };

  factory LinkPreview.fromMap(Map<String, dynamic> m) => LinkPreview(
    url: m['url'] as String,
    title: m['title'] as String?,
    image: m['image'] as String?,
    site: m['site'] as String?,
    kind: m['kind'] as String? ?? 'web',
    videoId: m['videoId'] as String?,
  );

  static final _urlRe = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);

  static String? firstUrl(String text) => _urlRe.firstMatch(text)?.group(0);

  static String? youtubeId(String url) {
    final m = RegExp(r'(?:youtube\.com/(?:watch\?(?:.*&)?v=|shorts/|embed/|live/)|youtu\.be/)([A-Za-z0-9_-]{11})')
        .firstMatch(url);
    return m?.group(1);
  }

  static String? tiktokId(String url) => RegExp(r'/video/(\d+)').firstMatch(url)?.group(1);

  static String kindOf(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (youtubeId(url) != null) return 'youtube';
    if (host.contains('tiktok.com')) return 'tiktok';
    if (host.contains('snapchat.com')) return 'snapchat';
    if (host.contains('instagram.com')) return 'instagram';
    if (host == 'x.com' || host.endsWith('.x.com') || host.contains('twitter.com')) return 'x';
    return 'web';
  }

  static const _ua = 'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)';

  static Future<LinkPreview?> fetch(String url) async {
    final kind = kindOf(url);
    try {
      if (kind == 'youtube') {
        final id = youtubeId(url)!;
        String? title;
        try {
          final r = await http
              .get(Uri.parse('https://www.youtube.com/oembed?format=json&url=${Uri.encodeComponent(url)}'))
              .timeout(const Duration(seconds: 8));
          if (r.statusCode == 200) title = jsonDecode(r.body)['title'] as String?;
        } catch (_) {}
        return LinkPreview(
          url: url,
          title: title,
          image: 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
          site: 'YouTube',
          kind: kind,
          videoId: id,
        );
      }

      if (kind == 'tiktok') {
        final r = await http
            .get(Uri.parse('https://www.tiktok.com/oembed?url=${Uri.encodeComponent(url)}'))
            .timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          final html = j['html'] as String? ?? '';
          final id = tiktokId(url) ?? RegExp(r'data-video-id="(\d+)"').firstMatch(html)?.group(1);
          return LinkPreview(
            url: url,
            title: j['title'] as String?,
            image: j['thumbnail_url'] as String?,
            site: 'TikTok',
            kind: kind,
            videoId: id,
          );
        }
      }

      final og = await _openGraph(url);
      if (og.isEmpty && kind == 'web') return null;
      return LinkPreview(
        url: url,
        title: og['title'],
        image: og['image'],
        site: og['site_name'] ?? Uri.parse(url).host.replaceFirst('www.', ''),
        kind: (kind == 'web' && og['video'] != null) ? 'webvideo' : kind,
      );
    } catch (_) {
      return kind == 'web' ? null : LinkPreview(url: url, kind: kind, site: Uri.parse(url).host);
    }
  }

  static Future<Map<String, String>> _openGraph(String url) async {
    final r = await http
        .get(Uri.parse(url), headers: {'User-Agent': _ua, 'Accept-Language': 'ar,en'})
        .timeout(const Duration(seconds: 8));
    if (r.statusCode >= 400) return {};
    final body = utf8.decode(r.bodyBytes, allowMalformed: true);
    final head = body.length > 300000 ? body.substring(0, 300000) : body;
    final out = <String, String>{};
    for (final tag in RegExp(r'<meta\s[^>]*>', caseSensitive: false).allMatches(head)) {
      final t = tag.group(0)!;
      final key = RegExp(
        r'''(?:property|name)\s*=\s*["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(t)?.group(1)?.toLowerCase();
      final content = RegExp(r'''content\s*=\s*["']([^"']*)["']''', caseSensitive: false).firstMatch(t)?.group(1);
      if (key == null || content == null || content.isEmpty) continue;
      for (final k in ['title', 'image', 'site_name', 'video']) {
        if (key == 'og:$k' || key == 'twitter:$k') out.putIfAbsent(k, () => _unescape(content));
      }
    }
    if (!out.containsKey('title')) {
      final m = RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false).firstMatch(head);
      if (m != null) out['title'] = _unescape(m.group(1)!.trim());
    }
    final img = out['image'];
    if (img != null && !img.startsWith('http')) out['image'] = Uri.parse(url).resolve(img).toString();
    return out;
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}

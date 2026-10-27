import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../l10n.dart';
import '../services/link_preview.dart';

/// Plays YouTube / TikTok / Snapchat / any link inside the app.
class WebVideoPage extends StatefulWidget {
  const WebVideoPage({super.key, required this.preview});

  final LinkPreview preview;

  @override
  State<WebVideoPage> createState() => _WebVideoPageState();
}

class _WebVideoPageState extends State<WebVideoPage> {
  late final WebViewController _controller;
  int _progress = 0;

  static const _origin = 'https://chat.app.local';

  @override
  void initState() {
    super.initState();
    final params = WebViewPlatform.instance is WebKitWebViewPlatform
        ? WebKitWebViewControllerCreationParams(
            allowsInlineMediaPlayback: true,
            mediaTypesRequiringUserAction: const {},
          )
        : const PlatformWebViewControllerCreationParams();

    _controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => mounted ? setState(() => _progress = p) : null,
          onNavigationRequest: (r) {
            // Keep app-store / intent links (e.g. "open in app" buttons) out of the webview.
            final u = Uri.tryParse(r.url);
            if (u != null && u.scheme != 'http' && u.scheme != 'https' && u.scheme != 'about' && u.scheme != 'data') {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );

    final android = _controller.platform;
    if (android is AndroidWebViewController) {
      android.setMediaPlaybackRequiresUserGesture(false);
    }
    _load();
  }

  void _load() {
    final p = widget.preview;
    final ytId = p.videoId ?? LinkPreview.youtubeId(p.url);
    if (p.kind == 'youtube' && ytId != null) {
      final html =
          '''
<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<style>html,body{margin:0;height:100%;background:#000;display:flex;align-items:center;justify-content:center}
iframe{width:100vw;height:56.25vw;max-height:100vh;border:0}</style></head><body>
<iframe src="https://www.youtube.com/embed/$ytId?autoplay=1&playsinline=1&rel=0&origin=$_origin"
 referrerpolicy="strict-origin-when-cross-origin"
 allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>
</body></html>''';
      _controller.loadHtmlString(html, baseUrl: _origin);
      return;
    }
    final tiktokId = p.kind == 'tiktok' ? (p.videoId ?? LinkPreview.tiktokId(p.url)) : null;
    if (tiktokId != null) {
      _controller.loadRequest(Uri.parse('https://www.tiktok.com/player/v1/$tiktokId?autoplay=1&loop=1&rel=0'));
      return;
    }
    _controller.loadRequest(Uri.parse(p.url));
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.preview.title ?? widget.preview.site ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: l.t('openInBrowser'),
            icon: const Icon(Icons.open_in_new),
            onPressed: () => launchUrl(Uri.parse(widget.preview.url), mode: LaunchMode.externalApplication),
          ),
        ],
        bottom: _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress / 100, minHeight: 2),
              )
            : null,
      ),
      body: SafeArea(child: WebViewWidget(controller: _controller)),
    );
  }
}

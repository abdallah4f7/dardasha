import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../widgets/common.dart';

class ImageViewerPage extends StatelessWidget {
  const ImageViewerPage({super.key, required this.url, required this.tag});

  final String url;
  final Object tag;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Center(
        child: InteractiveViewer(
          maxScale: 5,
          child: Hero(
            tag: tag,
            child: CachedNetworkImage(imageUrl: url, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key, required this.url});

  final String url;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final VideoPlayerController _c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    _c.addListener(() => setState(() {}));
    _c.initialize().then((_) => _c.play());
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _c.value;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: GestureDetector(
        onTap: () => setState(() => _showControls = !_showControls),
        child: Stack(
          children: [
            Center(
              child: v.isInitialized
                  ? AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(_c))
                  : const CircularProgressIndicator(color: Colors.white),
            ),
            if (_showControls && v.isInitialized) ...[
              Center(
                child: IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: Colors.black45),
                  iconSize: 48,
                  icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                  onPressed: () => v.isPlaying ? _c.pause() : _c.play(),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 24,
                child: SafeArea(
                  child: Directionality(
                    textDirection: TextDirection.ltr,
                    child: Row(
                      children: [
                        Text(formatDuration(v.position), style: const TextStyle(color: Colors.white)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: VideoProgressIndicator(
                            _c,
                            allowScrubbing: true,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            colors: const VideoProgressColors(playedColor: Colors.white, bufferedColor: Colors.white38),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(formatDuration(v.duration), style: const TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n.dart';
import '../services/api.dart';
import '../widgets/common.dart';

enum StickerShape { square, rounded, circle }

/// Pick a photo, pan/zoom it into a frame, choose a shape, add a caption → PNG sticker.
class StickerMakerPage extends StatefulWidget {
  const StickerMakerPage({super.key});

  @override
  State<StickerMakerPage> createState() => _StickerMakerPageState();
}

class _StickerMakerPageState extends State<StickerMakerPage> {
  final _boundary = GlobalKey();
  final _caption = TextEditingController();
  Uint8List? _image;
  StickerShape _shape = StickerShape.rounded;
  Color _textColor = Colors.white;
  Offset _textPos = const Offset(.5, .82); // fraction of the canvas
  bool _busy = false;

  static const _colors = [
    Colors.white,
    Colors.black,
    Color(0xFFFFD60A),
    Color(0xFFFF453A),
    Color(0xFF32D74B),
    Color(0xFF0A84FF),
  ];

  @override
  void initState() {
    super.initState();
    _caption.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
  }

  Future<void> _pick() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1200);
    if (x == null) {
      if (_image == null && mounted) Navigator.pop(context);
      return;
    }
    final bytes = await x.readAsBytes();
    setState(() => _image = bytes);
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final boundary = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 512 / boundary.size.width);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      final url = await Api.upload(data!.buffer.asUint8List(), 'png', 'image/png');
      await Api.saveSticker(url);
      if (!mounted) return;
      toast(context, L.of(context).t('stickerSaved'));
      Navigator.pop(context, url);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _clip(Widget child) => switch (_shape) {
    StickerShape.circle => ClipOval(child: child),
    StickerShape.rounded => ClipRRect(borderRadius: BorderRadius.circular(48), child: child),
    StickerShape.square => ClipRect(child: child),
  };

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final side = (MediaQuery.sizeOf(context).width - 48).clamp(200.0, 380.0);
    final caption = _caption.text.trim();
    final image = _image;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.t('makeSticker')),
        actions: [
          IconButton(tooltip: l.t('pickImage'), icon: const Icon(Icons.photo_library_outlined), onPressed: _pick),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: FilledButton(onPressed: image == null || _busy ? null : _save, child: Text(l.t('save'))),
          ),
        ],
      ),
      body: image == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (_busy) const LinearProgressIndicator(),
                Center(
                  child: CustomPaint(
                    painter: _Checkerboard(),
                    child: RepaintBoundary(
                      key: _boundary,
                      child: SizedBox.square(
                        dimension: side,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: _clip(
                                InteractiveViewer(
                                  minScale: .3,
                                  maxScale: 6,
                                  boundaryMargin: const EdgeInsets.all(double.infinity),
                                  child: Image.memory(image, fit: BoxFit.cover, width: side, height: side),
                                ),
                              ),
                            ),
                            if (caption.isNotEmpty)
                              Positioned(
                                left: 0,
                                right: 0,
                                top: _textPos.dy * side - 24,
                                child: GestureDetector(
                                  onPanUpdate: (d) => setState(() {
                                    _textPos = Offset(.5, (_textPos.dy + d.delta.dy / side).clamp(.08, .92));
                                  }),
                                  child: _OutlinedText(caption, color: _textColor, size: side / 9),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(l.t('shape'), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                SegmentedButton<StickerShape>(
                  segments: const [
                    ButtonSegment(value: StickerShape.square, icon: Icon(Icons.crop_square)),
                    ButtonSegment(value: StickerShape.rounded, icon: Icon(Icons.rounded_corner)),
                    ButtonSegment(value: StickerShape.circle, icon: Icon(Icons.circle_outlined)),
                  ],
                  selected: {_shape},
                  onSelectionChanged: (s) => setState(() => _shape = s.first),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _caption,
                  maxLength: 30,
                  decoration: InputDecoration(hintText: l.t('addText'), prefixIcon: const Icon(Icons.text_fields)),
                ),
                Wrap(
                  spacing: 10,
                  children: [
                    for (final c in _colors)
                      GestureDetector(
                        onTap: () => setState(() => _textColor = c),
                        child: CircleAvatar(
                          radius: 16,
                          backgroundColor: Theme.of(context).colorScheme.outline,
                          child: CircleAvatar(radius: _textColor == c ? 11 : 14, backgroundColor: c),
                        ),
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}

class _OutlinedText extends StatelessWidget {
  const _OutlinedText(this.text, {required this.color, required this.size});

  final String text;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final outline = color.computeLuminance() > .5 ? Colors.black : Colors.white;
    final base = TextStyle(fontSize: size, fontWeight: FontWeight.w900, height: 1.1);
    return Stack(
      alignment: Alignment.center,
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: base.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = size / 6
              ..strokeJoin = StrokeJoin.round
              ..color = outline,
          ),
        ),
        Text(
          text,
          textAlign: TextAlign.center,
          style: base.copyWith(color: color),
        ),
      ],
    );
  }
}

class _Checkerboard extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const s = 12.0;
    final a = Paint()..color = const Color(0xFFE0E0E0);
    final b = Paint()..color = const Color(0xFFFFFFFF);
    for (var y = 0.0; y < size.height; y += s) {
      for (var x = 0.0; x < size.width; x += s) {
        final even = ((x / s).floor() + (y / s).floor()).isEven;
        canvas.drawRect(Rect.fromLTWH(x, y, s, s), even ? a : b);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

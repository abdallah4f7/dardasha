import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n.dart';
import '../models.dart';
import '../services/api.dart';
import '../services/moderation.dart';
import '../widgets/common.dart';

/// Brings the owner each photo or video the checks weren't sure of, while the
/// sender waits. Runs for moderators while the app is open.
class ReviewDesk {
  static RealtimeChannel? _channel;
  static final _queue = <String>[];
  static bool _showing = false;

  static void start() {
    if (_channel != null) return;
    _channel = db
        .channel('reviews:desk')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'reviews',
          callback: (p) {
            final id = p.newRecord['id'];
            if (id is! String) return;
            _queue.add(id);
            if (!_showing) _next();
          },
        )
        .subscribe();
  }

  static void stop() {
    if (_channel != null) db.removeChannel(_channel!);
    _channel = null;
    _queue.clear();
  }

  static Future<void> _next() async {
    _showing = true;
    try {
      while (_queue.isNotEmpty) {
        final id = _queue.removeAt(0);
        // Gone once the sender stopped waiting.
        final row = await db.from('reviews').select().eq('id', id).maybeSingle();
        final nav = Moderation.navigatorKey?.currentState;
        if (row == null || row['decision'] != null || nav == null) continue;
        await nav.push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => ReviewPage(row: row)));
      }
    } catch (_) {
      // The next review starts the queue again.
    } finally {
      _showing = false;
    }
  }
}

class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key, required this.row});

  final Map<String, dynamic> row;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  static const _brush = 0.06; // of the picture's longer side

  late final String _id = widget.row['id'] as String;
  late final List<String> _reasons = [for (final r in widget.row['reasons'] as List) r as String];
  late final List<Mark> _marks = [
    for (final m in widget.row['marks'] as List? ?? const []) Mark.fromMap((m as Map).cast<String, dynamic>()),
  ];
  late final Uint8List? _preview = _decode(widget.row['preview'] as String?);
  ui.Size? _size;
  Profile? _sender;

  final _strokes = <List<Offset>>[];
  final _text = TextEditingController();

  // Counted from when it arrived here, a little short for the trip back.
  final _opened = DateTime.now();
  Duration _limit = Moderation.reviewWait - const Duration(seconds: 1);
  bool _holding = false;
  bool _answered = false;
  Timer? _tick;

  static Uint8List? _decode(String? dataUrl) {
    if (dataUrl == null || !dataUrl.contains(',')) return null;
    try {
      return base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    final bytes = _preview;
    if (bytes != null) {
      decodeImageFromList(bytes).then((img) {
        if (mounted) setState(() => _size = ui.Size(img.width.toDouble(), img.height.toDouble()));
      });
    }
    Api.profile(widget.row['sender_id'] as String).then((p) {
      if (mounted) setState(() => _sender = p);
    });
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      if (_left <= Duration.zero) {
        _tick?.cancel();
        if (!_answered) {
          toast(context, L.of(context).t('reviewMissed'));
          Navigator.of(context).pop();
        }
        return;
      }
      setState(() {});
    });
    _text.addListener(() {
      _hold();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _text.dispose();
    super.dispose();
  }

  Duration get _left => _limit - DateTime.now().difference(_opened);

  /// Started answering: the sender waits longer.
  void _hold() {
    if (_holding) return;
    setState(() {
      _holding = true;
      _limit = Moderation.reviewHold - const Duration(seconds: 2);
    });
    db.from('reviews').update({'holding': true}).eq('id', _id).then((_) {}, onError: (_) {});
  }

  Future<void> _answer(Decision d) async {
    if (_answered) return;
    setState(() => _answered = true);
    try {
      await db.from('reviews').update({'decision': d.toMap()}).eq('id', _id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _answered = false);
      showError(context, e);
    }
  }

  List<({double width, List<double> points})> get _drawn => [
    for (final s in _strokes) (width: _brush, points: [for (final p in s) ...[p.dx, p.dy]]),
  ];

  bool get _hasMine => _strokes.isNotEmpty || _text.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final scheme = Theme.of(context).colorScheme;
    final left = _left.inMilliseconds / _limit.inMilliseconds;
    final musicOnly = _reasons.length == 1 && _reasons.first == 'music';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${l.t(widget.row['kind'] == 'video' ? 'reviewVideo' : 'reviewPhoto')}'
          '${_sender == null ? '' : ' · ${_sender!.displayName}'}',
        ),
        actions: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 16),
            child: SizedBox(
              width: 32,
              height: 32,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(value: left.clamp(0, 1), strokeWidth: 3),
                  Text('${(_left.inMilliseconds / 1000).ceil().clamp(0, 99)}', style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final r in _reasons)
                    Chip(
                      avatar: Icon(Icons.help_outline, size: 18, color: scheme.tertiary),
                      label: Text(l.t('reason_$r')),
                    ),
                ],
              ),
            ),
            if (_holding)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(l.t('reviewHeld'), style: TextStyle(color: scheme.outline, fontSize: 12)),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Center(child: _picture(scheme)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      onTap: _hold,
                      decoration: InputDecoration(hintText: l.t('reviewTextHint')),
                    ),
                  ),
                  IconButton(
                    tooltip: l.t('undo'),
                    onPressed: _strokes.isEmpty ? null : () => setState(_strokes.removeLast),
                    icon: const Icon(Icons.undo),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: _answered
                        ? null
                        : () => _answer(Decision(unsure: true, text: _text.text, strokes: _drawn)),
                    child: Text(l.t(musicOnly ? 'muteIt' : 'blurUnsure')),
                  ),
                  if (_hasMine)
                    FilledButton.tonal(
                      onPressed: _answered ? null : () => _answer(Decision(text: _text.text, strokes: _drawn)),
                      child: Text(l.t('blurMine')),
                    ),
                  OutlinedButton(
                    onPressed: _answered ? null : () => _answer(const Decision()),
                    child: Text(l.t('sendAsIs')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _picture(ColorScheme scheme) {
    final bytes = _preview;
    final size = _size;
    if (bytes == null || size == null) {
      return Text(L.of(context).t('reviewHint'), textAlign: TextAlign.center);
    }
    return AspectRatio(
      aspectRatio: size.width / size.height,
      child: LayoutBuilder(
        builder: (context, box) {
          final area = box.biggest;
          Offset at(Offset local) => Offset((local.dx / area.width).clamp(0, 1), (local.dy / area.height).clamp(0, 1));
          return GestureDetector(
            onPanStart: (d) {
              _hold();
              setState(() => _strokes.add([at(d.localPosition)]));
            },
            onPanUpdate: (d) => setState(() => _strokes.last.add(at(d.localPosition))),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(bytes, fit: BoxFit.fill, gaplessPlayback: true),
                  CustomPaint(
                    painter: _MarksPainter(
                      marks: _marks,
                      strokes: _strokes,
                      brush: _brush * (area.width > area.height ? area.width : area.height),
                      unsure: scheme.tertiary,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Boxes around what the checks weren't sure of, and what the owner has drawn.
class _MarksPainter extends CustomPainter {
  _MarksPainter({required this.marks, required this.strokes, required this.brush, required this.unsure});

  final List<Mark> marks;
  final List<List<Offset>> strokes;
  final double brush;
  final Color unsure;

  @override
  void paint(Canvas canvas, Size size) {
    final box = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = unsure;
    for (final m in marks.where((m) => !m.sure)) {
      final r = Rect.fromLTWH(
        m.rect.left * size.width,
        m.rect.top * size.height,
        m.rect.width * size.width,
        m.rect.height * size.height,
      );
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)), box);
    }
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = brush
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.red.withValues(alpha: 0.45);
    for (final s in strokes) {
      final path = Path()..moveTo(s.first.dx * size.width, s.first.dy * size.height);
      for (final p in s.skip(1)) {
        path.lineTo(p.dx * size.width, p.dy * size.height);
      }
      if (s.length == 1) path.lineTo(s.first.dx * size.width + 0.1, s.first.dy * size.height);
      canvas.drawPath(path, pen);
    }
  }

  @override
  bool shouldRepaint(_MarksPainter old) => true;
}

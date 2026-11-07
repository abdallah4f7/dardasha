import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';
import 'moderation_stub.dart'
    if (dart.library.js_interop) 'moderation_web.dart'
    if (dart.library.io) 'moderation_io.dart'
    as engine;

/// Thrown when a photo or video couldn't be checked, so it isn't sent.
class CheckFailed implements Exception {
  const CheckFailed(this.cause);
  final Object cause;

  @override
  String toString() => 'CheckFailed: $cause';
}

/// A box on the owner's preview around something that was found, in 0–1 terms.
class Mark {
  Mark.fromMap(Map<String, dynamic> m)
    : rect = Rect.fromLTWH(
        (m['x'] as num).toDouble(),
        (m['y'] as num).toDouble(),
        (m['w'] as num).toDouble(),
        (m['h'] as num).toDouble(),
      ),
      kind = m['kind'] as String,
      sure = m['sure'] == true;

  final Rect rect;
  final String kind; // gender or awrah
  final bool sure;

  Map<String, dynamic> toMap() => {
    'x': rect.left,
    'y': rect.top,
    'w': rect.width,
    'h': rect.height,
    'kind': kind,
    'sure': sure,
  };
}

/// What web/moderate.js found in one photo or video.
class Check {
  Check.fromMap(Map<String, dynamic> m)
    : id = m['id'] as int,
      kind = m['kind'] as String,
      reasons = [for (final r in m['reasons'] as List) r as String],
      marks = [for (final x in m['marks'] as List) Mark.fromMap(x as Map<String, dynamic>)],
      preview = m['preview'] as String?;

  final int id;
  final String kind; // image or video

  /// What it wasn't sure of: gender, awrah, music. The owner is asked about these.
  final List<String> reasons;
  final List<Mark> marks;

  /// A small JPEG data URL of what it looked at, for the owner.
  final String? preview;
}

/// The owner's answer about a [Check]; see readDecision in web/moderate.js.
class Decision {
  const Decision({this.unsure = false, this.text = '', this.strokes = const []});

  /// Blur (or mute) the doubtful parts too.
  final bool unsure;

  /// What to blur, in their words: "الوجه والشعر".
  final String text;

  /// What they drew: each stroke's points as x, y pairs in 0–1 terms, and its width.
  final List<({double width, List<double> points})> strokes;

  Map<String, dynamic> toMap() => {
    'unsure': unsure,
    'text': text,
    'strokes': [
      for (final s in strokes) {'width': s.width, 'points': s.points},
    ],
  };

  static Decision fromMap(Map<String, dynamic> m) => Decision(
    unsure: m['unsure'] == true,
    text: m['text'] as String? ?? '',
    strokes: [
      for (final s in m['strokes'] as List? ?? const [])
        (
          width: ((s as Map)['width'] as num).toDouble(),
          points: [for (final p in s['points'] as List) (p as num).toDouble()],
        ),
    ],
  );
}

/// Before a photo or video is sent: a woman's face and hair are blurred, and
/// bare skin from the navel to the knees; a video with music loses its sound.
/// When the checks aren't sure, the owner gets [reviewWait] to look.
/// It all runs on the sender's device.
class Moderation {
  static const reviewWait = Duration(seconds: 10);

  /// Once the owner starts drawing or writing, they get this long in all.
  static const reviewHold = Duration(seconds: 60);

  /// Phones run the checks in a hidden web view, which needs an overlay to live in.
  static GlobalKey<NavigatorState>? navigatorKey;

  /// While the checks download for the first time: how far along, 0–1.
  static final preparing = ValueNotifier<double?>(null);

  /// The bytes to send instead of [bytes], or null when they can go as they are.
  /// [onProgress] gets 0–1 while it works, and null while it waits for the owner.
  static Future<Uint8List?> check(
    Uint8List bytes, {
    required String kind,
    required String conversationId,
    void Function(double? progress)? onProgress,
  }) async {
    Check c;
    try {
      c = Check.fromMap(
        jsonDecode(await engine.analyze(kind, bytes, (p) => onProgress?.call(p * 0.5))) as Map<String, dynamic>,
      );
    } catch (e) {
      throw CheckFailed(e);
    }
    try {
      Decision? decision;
      if (c.reasons.isNotEmpty) {
        onProgress?.call(null);
        decision = await _askOwner(c, conversationId);
      }
      return await engine.finish(
        c.id,
        decision == null ? '' : jsonEncode(decision.toMap()),
        (p) => onProgress?.call(0.5 + p * 0.5),
      );
    } catch (e) {
      if (e is CheckFailed) rethrow;
      throw CheckFailed(e);
    } finally {
      engine.drop(c.id);
    }
  }

  /// Puts [c] in front of the owner and waits for their answer: null when it
  /// doesn't come in time, or the review can't be made at all.
  static Future<Decision?> _askOwner(Check c, String conversationId) async {
    final String id;
    try {
      final row = await db
          .from('reviews')
          .insert({
            'conversation_id': conversationId,
            'kind': c.kind,
            'reasons': c.reasons,
            'preview': c.preview ?? '',
            'marks': [for (final m in c.marks) m.toMap()],
          })
          .select('id')
          .single();
      id = row['id'] as String;
    } catch (_) {
      return null; // nobody to ask: it goes as it would after the wait
    }

    final answer = Completer<Decision?>();
    var holding = false;
    void take(Map<String, dynamic> r) {
      if (answer.isCompleted) return;
      final d = r['decision'];
      if (d is Map) {
        answer.complete(Decision.fromMap(d.cast<String, dynamic>()));
      } else if (r['holding'] == true) {
        holding = true;
      }
    }

    final channel = db
        .channel('review:$id')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'reviews',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: id),
          callback: (p) => take(p.newRecord),
        )
        .subscribe();
    // Realtime can miss an update, so the row is also read now and then.
    final poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final r = await db.from('reviews').select('holding, decision').eq('id', id).maybeSingle();
        if (r != null) take(r);
      } catch (_) {}
    });
    try {
      final start = DateTime.now();
      while (!answer.isCompleted) {
        final limit = holding ? reviewHold : reviewWait;
        final left = limit - DateTime.now().difference(start);
        if (left <= Duration.zero) break;
        await Future.any([answer.future, Future<void>.delayed(left < const Duration(seconds: 1) ? left : const Duration(seconds: 1))]);
      }
      return answer.isCompleted ? await answer.future : null;
    } finally {
      poll.cancel();
      db.removeChannel(channel);
      db.from('reviews').delete().eq('id', id).then((_) {}, onError: (_) {});
    }
  }
}

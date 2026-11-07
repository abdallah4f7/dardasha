import 'dart:ui';

import 'package:chat/services/moderation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a check reads what moderate.js returns', () {
    final c = Check.fromMap({
      'id': 3,
      'kind': 'image',
      'reasons': ['gender'],
      'marks': [
        {'x': 0.1, 'y': 0.2, 'w': 0.3, 'h': 0.4, 'kind': 'gender', 'sure': false},
      ],
      'changes': true,
      'preview': 'data:image/jpeg;base64,AAAA',
    });
    expect(c.id, 3);
    expect(c.reasons, ['gender']);
    expect(c.marks.single.rect, const Rect.fromLTWH(0.1, 0.2, 0.3, 0.4));
    expect(c.marks.single.sure, isFalse);
    expect(c.marks.single.toMap()['kind'], 'gender');
  });

  test('a decision survives the trip through the database', () {
    const d = Decision(
      unsure: true,
      text: 'الوجه والشعر',
      strokes: [(width: 0.06, points: [0.1, 0.2, 0.3, 0.4])],
    );
    final back = Decision.fromMap(d.toMap());
    expect(back.unsure, isTrue);
    expect(back.text, 'الوجه والشعر');
    expect(back.strokes.single.width, 0.06);
    expect(back.strokes.single.points, [0.1, 0.2, 0.3, 0.4]);
  });

  test('an empty answer blurs only what was sure', () {
    final d = Decision.fromMap({});
    expect(d.unsure, isFalse);
    expect(d.text, isEmpty);
    expect(d.strokes, isEmpty);
  });
}

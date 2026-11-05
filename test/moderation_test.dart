import 'package:chat/models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _report() => {
  'id': 'r1',
  'reported_id': 'u2',
  'message_type': 'text',
  'message_content': 'hello',
  'message_media_url': null,
  'message_at': '2026-11-01T10:00:00Z',
  'note': null,
  'status': 'open',
  'action': null,
  'reason': null,
  'reporter': null,
  'reported': null,
};

void main() {
  test('a ban without an end is permanent', () {
    expect(Ban.fromMap({'until': null, 'reason': 'x'}).active, isTrue);
  });

  test('a temporary ban ends', () {
    final later = DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String();
    final earlier = DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String();
    expect(Ban.fromMap({'until': later}).active, isTrue);
    expect(Ban.fromMap({'until': earlier}).active, isFalse);
  });

  test('a report without a note or decision reads as open', () {
    final r = Report.fromMap(_report());
    expect(r.open, isTrue);
    expect(r.note, isNull);
    expect(r.action, isNull);
    expect(r.reporter, isNull);
  });

  test('a handled report keeps its decision', () {
    final r = Report.fromMap({..._report(), 'status': 'resolved', 'action': 'temp_ban', 'reason': 'spam'});
    expect(r.open, isFalse);
    expect(r.action, 'temp_ban');
    expect(r.reason, 'spam');
  });
}

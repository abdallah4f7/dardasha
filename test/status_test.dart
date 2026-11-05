import 'package:chat/models.dart';
import 'package:chat/pages/status_page.dart';
import 'package:flutter_test/flutter_test.dart';

Message _status(String id, String sender, int minute) => Message.fromMap({
  'id': id,
  'conversation_id': 'c-$sender',
  'sender_id': sender,
  'type': 'text',
  'content': id,
  'media_url': null,
  'meta': <String, dynamic>{},
  'created_at': DateTime.utc(2026, 11, 5, 12, minute).toIso8601String(),
});

void main() {
  test('keeps each person together, whoever posted last first', () {
    final sorted = sortStatuses([_status('a1', 'a', 1), _status('b1', 'b', 2), _status('a2', 'a', 3)], {});
    expect(sorted.map((g) => g.map((m) => m.id).toList()), [
      ['a1', 'a2'],
      ['b1'],
    ]);
  });

  test('someone with an unseen status comes before someone newer already seen', () {
    final sorted = sortStatuses([_status('a1', 'a', 1), _status('b1', 'b', 2)], {'b1'});
    expect(sorted.first.first.senderId, 'a');
  });

  test('one unseen status is enough to count as unseen', () {
    final person = Profile(id: 'a', username: 'a', displayName: 'A');
    final group = StatusGroup(person, [_status('a1', 'a', 1), _status('a2', 'a', 2)]);
    expect(group.unseenBy({'a1'}), isTrue);
    expect(group.unseenBy({'a1', 'a2'}), isFalse);
  });
}

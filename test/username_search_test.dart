import 'package:chat/services/api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('strangers show up only when their username is typed nearly in full', () {
    expect(usernameFound('abo_dadadadae', 'abo_dadadadae'), isTrue);
    expect(usernameFound('abo_dadadadae', 'abo_dadadad'), isTrue); // two letters short
    expect(usernameFound('abo_dadadadae', '@ABO_DADADADA'), isTrue); // @ and case don't matter
    expect(usernameFound('abo_dadadadae', 'abo_dadada'), isFalse); // three short
    expect(usernameFound('abo_dadadadae', 'ab'), isFalse);
    expect(usernameFound('abo_dadadadae', ''), isFalse);
    expect(usernameFound('abd', 'a'), isTrue);
    expect(usernameFound('abcd', 'abx'), isFalse); // not the start of it
    expect(usernameFound('abc', 'a_c'), isFalse); // "_" is a letter here, not a wildcard
  });
}

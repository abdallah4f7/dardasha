import 'dart:typed_data';

// Where neither a browser nor a web view runs the checks: nothing can be sent unchecked.

Future<String> analyze(String kind, Uint8List bytes, void Function(double) progress) =>
    Future.error(UnsupportedError('no checks here'));

Future<Uint8List?> finish(int id, String decision, void Function(double) progress) =>
    Future.error(UnsupportedError('no checks here'));

void drop(int id) {}

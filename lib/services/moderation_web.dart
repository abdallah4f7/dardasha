import 'dart:js_interop';
import 'dart:typed_data';

/// The page's `window.dardashaModerate`, from web/moderate.js.
@JS('dardashaModerate')
external _Moderate? get _moderate;

extension type _Moderate._(JSObject _) implements JSObject {
  external JSPromise<JSString> analyze(String kind, JSUint8Array bytes, JSFunction progress);
  external JSPromise<JSUint8Array?> finish(int id, String decision, JSFunction progress);
  external void drop(int id);
}

_Moderate get _m => _moderate ?? (throw StateError('moderate.js is not loaded'));

JSFunction _progress(void Function(double) f) => ((JSNumber p) => f(p.toDartDouble)).toJS;

Future<String> analyze(String kind, Uint8List bytes, void Function(double) progress) async =>
    (await _m.analyze(kind, bytes.toJS, _progress(progress)).toDart).toDart;

Future<Uint8List?> finish(int id, String decision, void Function(double) progress) async =>
    (await _m.finish(id, decision, _progress(progress)).toDart)?.toDart;

void drop(int id) => _moderate?.drop(id);

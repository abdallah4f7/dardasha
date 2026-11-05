import 'dart:js_interop';

import 'package:dart_webrtc/dart_webrtc.dart';
import 'package:web/web.dart' as web;

/// The page's `window.dardashaFx`, from web/camera_fx.js.
@JS('dardashaFx')
external _Fx? get _fx;

extension type _Fx._(JSObject _) implements JSObject {
  external bool get available;
  external void set(double brightness, double gray, bool blur);
  external web.MediaStream start(web.MediaStream camera);
  external void stop();
}

bool get available => _fx?.available ?? false;

void set(double brightness, double gray, bool blur) => _fx?.set(brightness, gray, blur);

MediaStream start(MediaStream camera) => MediaStreamWeb(_fx!.start((camera as MediaStreamWeb).jsStream), 'local');

void stop() => _fx?.stop();

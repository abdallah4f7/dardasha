import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'camera_fx_stub.dart' if (dart.library.js_interop) 'camera_fx_web.dart' as browser;

/// Changes this device's camera picture before it leaves the device, so everyone
/// in the call sees it and only the person whose camera it is can change it.
/// Android edits the frames in native code (CameraFx.kt), browsers on a canvas
/// (web/camera_fx.js). iPhone apps don't have it.
class CameraFx {
  CameraFx._();

  static const _channel = MethodChannel('dardasha/camera_fx');

  static bool get supported => kIsWeb ? browser.available : defaultTargetPlatform == TargetPlatform.android;

  /// -1 (darkest) to 1 (brightest).
  static double brightness = 0;

  /// 0 (full color) to 1 (black and white).
  static double gray = 0;
  static bool blurFaces = false;

  static bool get anyOn => brightness != 0 || gray != 0 || blurFaces;

  static Future<void> attach(String? trackId) async {
    if (kIsWeb || !supported || trackId == null) return;
    try {
      await _channel.invokeMethod('attach', {'track': trackId});
    } on PlatformException catch (_) {} // the call carries on with the plain camera
  }

  static Future<void> apply() async {
    if (!supported) return;
    if (kIsWeb) return browser.set(brightness, gray, blurFaces);
    await _channel.invokeMethod('set', {'brightness': brightness, 'gray': gray, 'blur': blurFaces});
  }

  static Future<void> reset() async {
    brightness = 0;
    gray = 0;
    blurFaces = false;
    await apply();
  }

  /// Browsers can't change a camera track in place: this is a second stream that
  /// carries the edited picture.
  static MediaStream startEditing(MediaStream camera) => browser.start(camera);

  static void stopEditing() => browser.stop();
}

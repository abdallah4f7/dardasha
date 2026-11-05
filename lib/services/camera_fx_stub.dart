import 'package:flutter_webrtc/flutter_webrtc.dart';

// Phones edit the camera's own frames instead (CameraFx.kt).

bool get available => false;

void set(double brightness, double gray, bool blur) {}

MediaStream start(MediaStream camera) => camera;

void stop() {}

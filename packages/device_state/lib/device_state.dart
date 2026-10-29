import 'package:flutter/services.dart';

const _channel = MethodChannel('dardasha/device_state');

/// True when the screen is on and unlocked (the person is using the phone).
/// Unknown (no Android, or the check failed) counts as not in use.
Future<bool> phoneInUse() async {
  try {
    return await _channel.invokeMethod<bool>('inUse') ?? false;
  } catch (_) {
    return false;
  }
}

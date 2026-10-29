package com.dardasha.device_state;

import android.app.KeyguardManager;
import android.content.Context;
import android.os.PowerManager;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodChannel;

/** Registered in every Flutter engine, including the one that handles pushes in the background. */
public class DeviceStatePlugin implements FlutterPlugin {
    private MethodChannel channel;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        Context context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "dardasha/device_state");
        channel.setMethodCallHandler((call, result) -> {
            if (!call.method.equals("inUse")) {
                result.notImplemented();
                return;
            }
            PowerManager power = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
            KeyguardManager keyguard = (KeyguardManager) context.getSystemService(Context.KEYGUARD_SERVICE);
            result.success(power.isInteractive() && !keyguard.isKeyguardLocked());
        });
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
    }
}

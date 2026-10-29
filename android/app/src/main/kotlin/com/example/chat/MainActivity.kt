package com.example.chat

import android.content.ComponentName
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dardasha/screen").setMethodCallHandler { call, result ->
            val intent = Intent(this, ScreenShareService::class.java)
            when (call.method) {
                "start" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                    result.success(null)
                }
                "stop" -> {
                    stopService(intent)
                    result.success(null)
                }
                // Only the call screen may show over the lock screen, and only during a call.
                "showOnLock" -> {
                    val on = call.arguments as Boolean
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                        setShowWhenLocked(on)
                        setTurnScreenOn(on)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dardasha/share").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "targets" -> result.success(shareTargets(call.argument<String>("mime")!!, call.argument<Int>("limit")!!))
                    "send" -> {
                        startActivity(sendIntent(call.argument("mime")!!, call.argument("text"), call.argument("path")).apply {
                            component = ComponentName(call.argument<String>("package")!!, call.argument<String>("activity")!!)
                        })
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("share", e.message, null)
            }
        }
    }

    private fun sendIntent(mime: String, text: String?, path: String?) = Intent(Intent.ACTION_SEND).apply {
        type = mime
        if (text != null) putExtra(Intent.EXTRA_TEXT, text)
        if (path != null) {
            putExtra(Intent.EXTRA_STREAM, FileProvider.getUriForFile(this@MainActivity, "$packageName.share", File(path)))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    // Apps that accept this kind of share, the popular messengers first, then in the system's order.
    private fun shareTargets(mime: String, limit: Int): List<Map<String, Any>> {
        val preferred = listOf(
            "com.whatsapp", "com.whatsapp.w4b", "com.snapchat.android", "org.telegram.messenger",
            "com.instagram.android", "com.twitter.android", "com.google.android.apps.messaging", "com.google.android.gm",
        )
        val found = packageManager.queryIntentActivities(Intent(Intent.ACTION_SEND).setType(mime), 0)
            .filter { it.activityInfo.packageName != packageName }
            .distinctBy { it.activityInfo.packageName }
            .sortedBy { preferred.indexOf(it.activityInfo.packageName).let { i -> if (i < 0) preferred.size else i } }
            .take(limit)
        return found.map {
            mapOf(
                "package" to it.activityInfo.packageName,
                "activity" to it.activityInfo.name,
                "label" to it.loadLabel(packageManager).toString(),
                "icon" to iconPng(it.loadIcon(packageManager)),
            )
        }
    }

    private fun iconPng(d: android.graphics.drawable.Drawable): ByteArray {
        val bmp = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, 96, 96)
        d.draw(Canvas(bmp))
        return ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    }
}

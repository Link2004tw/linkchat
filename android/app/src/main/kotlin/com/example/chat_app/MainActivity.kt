package com.example.chat_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "chat/battery",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoringOptimizations" -> result.success(isIgnoringBatteryOptimizations())
                "requestIgnoration" -> {
                    requestIgnoreBatteryOptimizations()
                    result.success(null)
                }
                "manufacturer" -> result.success(android.os.Build.MANUFACTURER)
                else -> result.notImplemented()
            }
        }
    }

    /**
     * FCM sends target the `messages` channel (see backend push.service.ts).
     * Channels must be created client-side before any notification arrives,
     * or Android falls back to "Miscellaneous", which OEM ROMs suppress when
     * the app process is dead.
     */
    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel("messages") != null) return

        val messages = NotificationChannel(
            "messages",
            "Messages",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "New messages and friend requests"
            enableVibration(true)
        }
        manager.createNotificationChannel(messages)
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    /** Launches the system dialog asking the user to exempt the app. */
    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val intent = android.content.Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:$packageName"),
        )
        startActivity(intent)
    }
}

package com.example.microzaimich

import android.content.Intent
import android.app.NotificationManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "loan_notifications"
    private val serviceChannelId = "loan_service_status"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val userId = call.argument<String>("userId")
                        val intent = Intent(this, LoanNotificationService::class.java).apply {
                            putExtra("userId", userId)
                        }
                        startForegroundService(intent)
                        result.success(null)
                    }

                    "stop" -> {
                        stopService(Intent(this, LoanNotificationService::class.java))
                        result.success(null)
                    }

                    "isRunning" -> {
                        result.success(LoanNotificationService.isRunning)
                    }

                    "isServiceNotificationEnabled" -> {
                        val manager = getSystemService(NotificationManager::class.java)
                        val appNotificationsEnabled = manager.areNotificationsEnabled()
                        val channel = manager.getNotificationChannel(serviceChannelId)
                        val channelEnabled = channel == null ||
                            channel.importance != NotificationManager.IMPORTANCE_NONE
                        result.success(appNotificationsEnabled && channelEnabled)
                    }

                    "openServiceNotificationSettings" -> {
                        val intent = Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
                            putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            putExtra(Settings.EXTRA_CHANNEL_ID, serviceChannelId)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }
}

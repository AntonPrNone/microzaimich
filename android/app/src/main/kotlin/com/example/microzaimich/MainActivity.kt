package com.example.microzaimich

import android.content.Intent
import android.content.Context
import android.app.NotificationManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "loan_notifications"
    private val serviceChannelId = "loan_service_status"
    private val servicePrefsName = "loan_notification_service"

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

                    "getReminderTime" -> {
                        val forAdmin = call.argument<Boolean>("forAdmin") ?: false
                        val prefs = getSharedPreferences(servicePrefsName, Context.MODE_PRIVATE)
                        val prefix = if (forAdmin) "admin" else "client"
                        val defaultHour = if (forAdmin) 18 else 10
                        result.success(
                            mapOf(
                                "hour" to prefs.getInt("${prefix}_reminder_hour", defaultHour),
                                "minute" to prefs.getInt("${prefix}_reminder_minute", 0),
                            )
                        )
                    }

                    "setReminderTime" -> {
                        val forAdmin = call.argument<Boolean>("forAdmin") ?: false
                        val hour = (call.argument<Int>("hour") ?: if (forAdmin) 18 else 10)
                            .coerceIn(0, 23)
                        val minute = (call.argument<Int>("minute") ?: 0).coerceIn(0, 59)
                        val prefs = getSharedPreferences(servicePrefsName, Context.MODE_PRIVATE)
                        val prefix = if (forAdmin) "admin" else "client"
                        prefs.edit()
                            .putInt("${prefix}_reminder_hour", hour)
                            .putInt("${prefix}_reminder_minute", minute)
                            .apply()
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }
}

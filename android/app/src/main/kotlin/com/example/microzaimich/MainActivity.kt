package com.example.microzaimich

import android.Manifest
import android.content.Intent
import android.content.Context
import android.content.pm.PackageManager
import android.app.NotificationManager
import android.provider.ContactsContract
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "loan_notifications"
    private val contactsChannel = "contact_import"
    private val serviceChannelId = "loan_service_status"
    private val servicePrefsName = "loan_notification_service"
    private val contactPickerRequestCode = 4101
    private val contactsPermissionRequestCode = 4102
    private var pendingContactResult: MethodChannel.Result? = null

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

                    "clearReminderCache" -> {
                        val prefs = getSharedPreferences(servicePrefsName, Context.MODE_PRIVATE)
                        prefs.edit().remove("sent_reminders").apply()
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, contactsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickClientContact" -> handlePickClientContact(result)
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode != contactsPermissionRequestCode) {
            return
        }

        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            launchContactPicker()
        } else {
            pendingContactResult?.error(
                "permission_denied",
                "READ_CONTACTS permission denied",
                null,
            )
            pendingContactResult = null
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode != contactPickerRequestCode) {
            return
        }

        val result = pendingContactResult
        pendingContactResult = null

        if (result == null) {
            return
        }

        if (resultCode != RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }

        val contactUri = data.data ?: run {
            result.success(null)
            return
        }

        try {
            val projection = arrayOf(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            )

            contentResolver.query(contactUri, projection, null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) {
                    result.error("empty_contact", "Selected contact has no phone data", null)
                    return
                }

                val nameIndex =
                    cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
                val numberIndex =
                    cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)

                val name =
                    if (nameIndex >= 0) cursor.getString(nameIndex).orEmpty() else ""
                val phone =
                    if (numberIndex >= 0) cursor.getString(numberIndex).orEmpty() else ""

                result.success(
                    mapOf(
                        "name" to name,
                        "phone" to phone,
                    )
                )
                return
            }

            result.error("query_failed", "Failed to read selected contact", null)
        } catch (error: Exception) {
            result.error("query_failed", error.message, null)
        }
    }

    private fun handlePickClientContact(result: MethodChannel.Result) {
        if (pendingContactResult != null) {
            result.error("already_active", "Another contact import is already in progress", null)
            return
        }

        pendingContactResult = result

        val hasPermission =
            ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CONTACTS) ==
                PackageManager.PERMISSION_GRANTED

        if (hasPermission) {
            launchContactPicker()
            return
        }

        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.READ_CONTACTS),
            contactsPermissionRequestCode,
        )
    }

    private fun launchContactPicker() {
        val intent = Intent(
            Intent.ACTION_PICK,
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
        )
        startActivityForResult(intent, contactPickerRequestCode)
    }
}

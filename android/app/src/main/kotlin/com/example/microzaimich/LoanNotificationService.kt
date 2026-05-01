package com.example.microzaimich

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import com.google.firebase.Timestamp
import com.google.firebase.firestore.DocumentChange
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import java.util.Calendar
import java.util.Date

class LoanNotificationService : Service() {

    companion object {
        @Volatile
        var isRunning: Boolean = false

        private const val EXTRA_USER_ID = "userId"
        private const val PREFS_NAME = "loan_notification_service"
        private const val KEY_USER_ID = "active_user_id"
        private const val KEY_BOOTSTRAPPED = "listener_bootstrapped"
        private const val KEY_DELIVERED_IDS = "delivered_ids"
        private const val KEY_SENT_REMINDERS = "sent_reminders"
    }

    private val serviceChannelId = "loan_service_status"
    private val updatesChannelId = "loan_updates"
    private val remindersChannelId = "loan_reminders"
    private val handler = Handler(Looper.getMainLooper())
    private val reminderChecker = object : Runnable {
        override fun run() {
            val userId = activeUserId
            if (!userId.isNullOrBlank()) {
                checkLoanReminders(userId)
            }
            handler.postDelayed(this, 15 * 60 * 1000L)
        }
    }
    private var listenerRegistration: ListenerRegistration? = null
    private var loansListenerRegistration: ListenerRegistration? = null
    private lateinit var prefs: SharedPreferences
    private var activeUserId: String? = null

    override fun onCreate() {
        super.onCreate()
        prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        isRunning = true
        createChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val incomingUserId = intent?.getStringExtra(EXTRA_USER_ID)
            ?: prefs.getString(KEY_USER_ID, null)

        if (incomingUserId.isNullOrBlank()) {
            stopSelf()
            return START_NOT_STICKY
        }

        val switchedUser = activeUserId != null && activeUserId != incomingUserId
        if (switchedUser) {
            clearDeliveredState()
        }

        activeUserId = incomingUserId
        prefs.edit().putString(KEY_USER_ID, incomingUserId).apply()

        val notification = NotificationCompat.Builder(this, serviceChannelId)
            .setContentTitle("Синхронизация займов")
            .setContentText("Фоновые уведомления включены")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(createLaunchPendingIntent())
            .build()

        startForeground(
            1,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        )

        attachNotificationsListener(incomingUserId)
        attachLoansListener(incomingUserId)
        checkLoanReminders(incomingUserId)
        handler.removeCallbacks(reminderChecker)
        handler.post(reminderChecker)
        return START_STICKY
    }

    private fun createChannels() {
        val manager = getSystemService(NotificationManager::class.java)

        val serviceChannel = NotificationChannel(
            serviceChannelId,
            "Статус сервиса уведомлений",
            NotificationManager.IMPORTANCE_MIN
        )
        serviceChannel.setSound(null, null)
        serviceChannel.enableVibration(false)

        val updatesChannel = NotificationChannel(
            updatesChannelId,
            "События по займам",
            NotificationManager.IMPORTANCE_HIGH
        )

        val remindersChannel = NotificationChannel(
            remindersChannelId,
            "Напоминания о платежах",
            NotificationManager.IMPORTANCE_HIGH
        )

        manager.createNotificationChannel(serviceChannel)
        manager.createNotificationChannel(updatesChannel)
        manager.createNotificationChannel(remindersChannel)
    }

    private fun attachNotificationsListener(userId: String) {
        listenerRegistration?.remove()
        listenerRegistration = FirebaseFirestore.getInstance()
            .collection("notifications")
            .whereEqualTo("userId", userId)
            .addSnapshotListener { snapshot, _ ->
                if (snapshot == null) {
                    return@addSnapshotListener
                }

                val bootstrapped = prefs.getBoolean(KEY_BOOTSTRAPPED, false)
                val delivered = prefs.getStringSet(KEY_DELIVERED_IDS, emptySet())?.toMutableSet()
                    ?: mutableSetOf()

                if (!bootstrapped) {
                    snapshot.documents.forEach { delivered.add(it.id) }
                    prefs.edit()
                        .putBoolean(KEY_BOOTSTRAPPED, true)
                        .putStringSet(KEY_DELIVERED_IDS, delivered)
                        .apply()
                    return@addSnapshotListener
                }

                var changed = false
                for (change in snapshot.documentChanges) {
                    if (change.type != DocumentChange.Type.ADDED) {
                        continue
                    }
                    val doc = change.document
                    if (delivered.contains(doc.id)) {
                        continue
                    }
                    if (doc.getTimestamp("readAt") != null) {
                        delivered.add(doc.id)
                        changed = true
                        continue
                    }

                    val title = doc.getString("title").orEmpty()
                    val body = doc.getString("body").orEmpty()
                    if (title.isNotBlank() || body.isNotBlank()) {
                        showUpdateNotification(doc.id, title, body)
                    }
                    delivered.add(doc.id)
                    changed = true
                }

                if (changed) {
                    prefs.edit().putStringSet(KEY_DELIVERED_IDS, delivered).apply()
                }
            }
    }

    private fun attachLoansListener(userId: String) {
        loansListenerRegistration?.remove()
        loansListenerRegistration = FirebaseFirestore.getInstance()
            .collection("loans")
            .whereEqualTo("userId", userId)
            .whereEqualTo("status", "active")
            .addSnapshotListener { snapshot, _ ->
                if (snapshot == null) {
                    return@addSnapshotListener
                }
                checkLoanReminders(userId)
            }
    }

    private fun showUpdateNotification(documentId: String, title: String, body: String) {
        val notification = NotificationCompat.Builder(this, updatesChannelId)
            .setContentTitle(title.ifBlank { "Новое уведомление" })
            .setContentText(body.ifBlank { "Появилось новое событие по займу" })
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText(body.ifBlank { "Появилось новое событие по займу" })
            )
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(createLaunchPendingIntent())
            .build()

        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(documentId.hashCode(), notification)
    }

    private fun checkLoanReminders(userId: String) {
        FirebaseFirestore.getInstance()
            .collection("loans")
            .whereEqualTo("userId", userId)
            .whereEqualTo("status", "active")
            .get()
            .addOnSuccessListener { snapshot ->
                val sentReminders = prefs.getStringSet(KEY_SENT_REMINDERS, emptySet())
                    ?.toMutableSet()
                    ?: mutableSetOf()
                var changed = false

                for (document in snapshot.documents) {
                    val loanLabel = loanLabel(document)
                    val schedule = document.get("schedule") as? List<*>
                    if (schedule == null) {
                        continue
                    }

                    for (row in schedule) {
                        val item = row as? Map<*, *> ?: continue
                        val isPaid = item["isPaid"] as? Boolean ?: false
                        if (isPaid) {
                            continue
                        }
                        val dueDate = parseDueDate(item["dueDate"]) ?: continue
                        val scheduleItemId = item["id"] as? String ?: continue
                        val amount = (item["amount"] as? Number)?.toDouble() ?: 0.0

                        val reminderKeys = listOf(
                            ReminderEntry(
                                key = "${document.id}_${scheduleItemId}_day_before",
                                shouldSend = isSameDay(shiftDay(dueDate, -1), Calendar.getInstance().time),
                                title = "Платёж уже завтра",
                                body = "$loanLabel: до ${formatDate(dueDate)} нужно внести ${formatMoney(amount)}",
                            ),
                            ReminderEntry(
                                key = "${document.id}_${scheduleItemId}_due_today",
                                shouldSend = isSameDay(dueDate, Calendar.getInstance().time),
                                title = "Сегодня срок платежа",
                                body = "$loanLabel: сегодня нужно внести ${formatMoney(amount)}",
                            ),
                        )

                        for (entry in reminderKeys) {
                            if (!entry.shouldSend || sentReminders.contains(entry.key)) {
                                continue
                            }
                            showReminderNotification(entry.key, entry.title, entry.body)
                            sentReminders.add(entry.key)
                            changed = true
                        }
                    }
                }

                if (changed) {
                    prefs.edit().putStringSet(KEY_SENT_REMINDERS, sentReminders).apply()
                }
            }
    }

    private fun parseDueDate(raw: Any?): Date? {
        return when (raw) {
            is com.google.firebase.Timestamp -> raw.toDate()
            is String -> parseIsoDate(raw)
            is Number -> Date(raw.toLong())
            else -> null
        }
    }

    private fun parseIsoDate(value: String): Date? {
        return try {
            Date.from(java.time.Instant.parse(value))
        } catch (_: Exception) {
            try {
                val localDateTime = java.time.LocalDateTime.parse(value)
                Date.from(
                    localDateTime
                        .atZone(java.time.ZoneId.systemDefault())
                        .toInstant()
                )
            } catch (_: Exception) {
                null
            }
        }
    }

    private fun showReminderNotification(notificationKey: String, title: String, body: String) {
        val notification = NotificationCompat.Builder(this, remindersChannelId)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(createLaunchPendingIntent())
            .build()

        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(notificationKey.hashCode(), notification)
        persistReminderToCenter(notificationKey, title, body)
    }

    private fun persistReminderToCenter(notificationKey: String, title: String, body: String) {
        val userId = activeUserId ?: return
        val documentId = "reminder_$notificationKey"
        FirebaseFirestore.getInstance()
            .collection("notifications")
            .document(documentId)
            .set(
                mapOf(
                    "userId" to userId,
                    "title" to title,
                    "body" to body,
                    "type" to "paymentReminder",
                    "createdAt" to Timestamp.now(),
                    "readAt" to null,
                ),
            )
    }

    private fun createLaunchPendingIntent(): PendingIntent? {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            this,
            1001,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun loanLabel(document: DocumentSnapshot): String {
        val timestamp = document.getTimestamp("issuedAt")
        val issuedAt = timestamp?.toDate() ?: return "Займ"
        val calendar = Calendar.getInstance().apply { time = issuedAt }
        val day = calendar.get(Calendar.DAY_OF_MONTH).toString().padStart(2, '0')
        val month = (calendar.get(Calendar.MONTH) + 1).toString().padStart(2, '0')
        val year = calendar.get(Calendar.YEAR).toString()
        return "Займ $day.$month.$year"
    }

    private fun formatDate(date: java.util.Date): String {
        val calendar = Calendar.getInstance().apply { time = date }
        val day = calendar.get(Calendar.DAY_OF_MONTH).toString().padStart(2, '0')
        val month = (calendar.get(Calendar.MONTH) + 1).toString().padStart(2, '0')
        val year = calendar.get(Calendar.YEAR).toString()
        return "$day.$month.$year"
    }

    private fun formatMoney(amount: Double): String {
        return String.format(java.util.Locale("ru", "RU"), "%,.2f ₽", amount)
    }

    private fun shiftDay(date: java.util.Date, days: Int): java.util.Date {
        return Calendar.getInstance().apply {
            time = date
            add(Calendar.DAY_OF_YEAR, days)
        }.time
    }

    private fun isSameDay(first: java.util.Date, second: java.util.Date): Boolean {
        val firstCalendar = Calendar.getInstance().apply { time = first }
        val secondCalendar = Calendar.getInstance().apply { time = second }
        return firstCalendar.get(Calendar.YEAR) == secondCalendar.get(Calendar.YEAR) &&
            firstCalendar.get(Calendar.DAY_OF_YEAR) == secondCalendar.get(Calendar.DAY_OF_YEAR)
    }

    private fun clearDeliveredState() {
        prefs.edit()
            .remove(KEY_BOOTSTRAPPED)
            .remove(KEY_DELIVERED_IDS)
            .apply()
    }

    override fun onDestroy() {
        handler.removeCallbacks(reminderChecker)
        listenerRegistration?.remove()
        listenerRegistration = null
        loansListenerRegistration?.remove()
        loansListenerRegistration = null
        activeUserId = null
        isRunning = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}

private data class ReminderEntry(
    val key: String,
    val shouldSend: Boolean,
    val title: String,
    val body: String,
)

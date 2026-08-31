package dev.g0spel.zflow

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Foreground service with two independent claims:
 * - running: tasks are executing; the notification shows live previews
 *   (driven from Dart's TaskNotifier via setRunning/releaseRunning).
 * - keepAlive: user-enabled background keep-alive; while set, the service
 *   never stops — releasing the running claim falls back to an idle
 *   "保持在线" notification, and a partial wake lock can be held while the
 *   screen is off so Doze cannot freeze the relay socket.
 *
 * The service stops only when BOTH claims are gone.
 */
class ZflowNotificationService : Service() {
    companion object {
        const val CHANNEL_RUNNING = "running_tasks"
        const val CHANNEL_COMPLETED = "task_completed"
        const val CHANNEL_APPROVAL = "task_approval"
        const val NOTIFICATION_ID = 1001
        private const val WAKE_LOCK_TAG = "zflow:keepalive"

        @Volatile
        var instance: ZflowNotificationService? = null
            private set

        fun start(context: Context, title: String, text: String) {
            val intent = Intent(context, ZflowNotificationService::class.java)
                .putExtra("title", title)
                .putExtra("text", text)
            context.startForegroundService(intent)
        }
    }

    @Volatile
    var keepAliveMode = false
        private set

    @Volatile
    var wakeLockEnabled = false
        private set

    @Volatile
    private var runningMode = false

    private var lastTitle: String = ""
    private var lastText: String = ""
    private var wakeLock: PowerManager.WakeLock? = null

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_OFF -> holdWakeLock()
                Intent.ACTION_SCREEN_ON -> releaseWakeLock()
            }
        }
    }

    private val powerManager: PowerManager
        get() = getSystemService(POWER_SERVICE) as PowerManager

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannels()
    }

    override fun onDestroy() {
        releaseWakeLock()
        try {
            unregisterReceiver(screenReceiver)
        } catch (_: IllegalArgumentException) {
        }
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastTitle = intent?.getStringExtra("title") ?: lastTitle
        lastText = intent?.getStringExtra("text") ?: lastText
        startForeground(NOTIFICATION_ID, buildNotification())
        syncScreenReceiver()
        syncWakeLock()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ------------------------------------------------------------ claims

    /** Dart: running-task content (setRunning). */
    fun setRunning(title: String, text: String) {
        runningMode = true
        update(title, text)
    }

    /** Dart: running claim released — fall back to keep-alive or stop. */
    fun releaseRunning() {
        runningMode = false
        if (!keepAliveMode) {
            stopSelf()
            return
        }
        updateKeepAliveIdle()
    }

    /** Dart: keep-alive enabled (wakeLock = hold a lock while screen off). */
    fun enableKeepAlive(wakeLock: Boolean) {
        val wasOff = !keepAliveMode
        keepAliveMode = true
        wakeLockEnabled = wakeLock
        if (wasOff || runningMode.not()) updateKeepAliveIdle()
        syncScreenReceiver()
        syncWakeLock()
    }

    /** Dart: keep-alive disabled — stop unless tasks are running. */
    fun disableKeepAlive() {
        keepAliveMode = false
        wakeLockEnabled = false
        releaseWakeLock()
        syncScreenReceiver()
        if (!runningMode) stopSelf()
    }

    fun update(title: String, text: String) {
        lastTitle = title
        lastText = text
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun updateKeepAliveIdle() {
        if (runningMode) return
        lastTitle = "Zflow 保持连接"
        lastText = "已连接 · 后台保持在线"
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun syncScreenReceiver() {
        val wanted = keepAliveMode
        val registered = screenReceiverRegistered
        if (wanted && !registered) {
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
            }
            registerReceiver(screenReceiver, filter)
            screenReceiverRegistered = true
        } else if (!wanted && registered) {
            unregisterReceiver(screenReceiver)
            screenReceiverRegistered = false
        }
    }

    private var screenReceiverRegistered = false

    private fun syncWakeLock() {
        if (keepAliveMode && wakeLockEnabled) {
            // Refresh holding state against the current screen state.
            if (powerManager.isInteractive) {
                releaseWakeLock()
            } else {
                holdWakeLock()
            }
        } else {
            releaseWakeLock()
        }
    }

    private fun holdWakeLock() {
        if (!keepAliveMode || !wakeLockEnabled) return
        if (wakeLock?.isHeld == true) return
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    // ------------------------------------------------------- notification

    private fun buildNotification(): Notification {
        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(
            this,
            0,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_RUNNING)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(lastTitle)
            .setContentText(lastText)
            .setStyle(NotificationCompat.BigTextStyle().bigText(lastText))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(pending)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
    }

    private fun createChannels() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_RUNNING,
                "运行中的任务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "后台运行时展示正在执行的任务及最新进展"
                setSound(null, null)
                enableVibration(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_COMPLETED,
                "任务完成与失败",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "任务完成或失败时静默提醒（不弹窗）"
                setSound(null, null)
                enableVibration(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_APPROVAL,
                "审批请求",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "任务等待权限批准或输入时横幅提醒"
            }
        )
    }
}

/** Task event notifications: approval (banner) or completion/failure (silent). */
object TaskNotifications {
    private var nextId = 2001

    /** [payload] is a JSON string the Dart side uses to deep-link into chat. */
    fun notify(
        context: Context,
        channel: String,
        title: String,
        text: String,
        payload: String?
    ) {
        val channelId = if (channel == "approval") {
            ZflowNotificationService.CHANNEL_APPROVAL
        } else {
            ZflowNotificationService.CHANNEL_COMPLETED
        }
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (channel == "approval") {
            nm.createNotificationChannel(
                NotificationChannel(
                    ZflowNotificationService.CHANNEL_APPROVAL,
                    "审批请求",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "任务等待权限批准或输入时横幅提醒"
                }
            )
        }
        val tapIntent = Intent(context, NotificationTapActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            if (payload != null) putExtra("notificationTask", payload)
        }
        val pending = PendingIntent.getActivity(
            context,
            nextId,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
        nm.notify(nextId, notification)
        nextId += 1
    }
}

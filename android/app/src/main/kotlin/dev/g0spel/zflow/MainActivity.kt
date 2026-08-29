package dev.g0spel.zflow

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "zflow/update"
    private val notifyChannelName = "zflow/notifications"
    private val navChannelName = "zflow/nav"

    private val notificationPermissionRequestCode = 4096

    /** Payload (JSON) of a tapped notification, consumed by the Dart side. */
    private var pendingNotificationPayload: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getApkDir" -> result.success(apkDir().absolutePath)
                "canInstall" -> result.success(canRequestPackageInstalls())
                "openInstallSettings" -> {
                    openInstallSettings()
                    result.success(true)
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    result.success(installApk(path))
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, notifyChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "startForeground" -> {
                    ZflowNotificationService.start(
                        this,
                        call.argument<String>("title") ?: "任务运行中",
                        call.argument<String>("text") ?: ""
                    )
                    result.success(true)
                }
                "updateForeground" -> {
                    val title = call.argument<String>("title") ?: "任务运行中"
                    val text = call.argument<String>("text") ?: ""
                    val service = ZflowNotificationService.instance
                    if (service != null) {
                        service.update(title, text)
                        result.success(true)
                    } else {
                        ZflowNotificationService.start(this, title, text)
                        result.success(true)
                    }
                }
                "stopForeground" -> {
                    stopService(Intent(this, ZflowNotificationService::class.java))
                    result.success(true)
                }
                "notifyTaskCompleted" -> {
                    TaskNotifications.notify(
                        this,
                        call.argument<String>("title") ?: "任务完成",
                        call.argument<String>("text") ?: "",
                        call.argument<String>("payload")
                    )
                    result.success(true)
                }
                "requestNotificationPermission" -> {
                    requestNotificationPermission()
                    result.success(true)
                }
                "hasNotificationPermission" -> {
                    result.success(hasNotificationPermission())
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, navChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getLaunchPayload" -> {
                    result.success(pendingNotificationPayload)
                    pendingNotificationPayload = null
                }
                "setTapHandler" -> {
                    // Handler registration is implicit (method channel callbacks);
                    // just acknowledge and deliver any pending payload.
                    result.success(pendingNotificationPayload)
                    pendingNotificationPayload = null
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingNotificationPayload = drainNotificationTapPayload()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val payload = drainNotificationTapPayload()
        if (payload != null) {
            pushPayloadToDart(payload)
        }
    }

    /**
     * Notification payloads are handed over in process memory by the
     * unexported [NotificationTapActivity] — never via intent extras on this
     * exported activity, so other apps cannot forge a deep link.
     */
    private fun drainNotificationTapPayload(): String? =
        NotificationTapActivity.pendingPayload?.also {
            NotificationTapActivity.clearPendingPayload()
        }

    private fun pushPayloadToDart(payload: String) {
        val engine = flutterEngine
        if (engine != null) {
            MethodChannel(engine.dartExecutor.binaryMessenger, navChannelName)
                .invokeMethod("onNotificationTap", payload, null)
        }
    }

    private fun hasNotificationPermission(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !hasNotificationPermission()
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationPermissionRequestCode
            )
        }
    }

    /** Internal dir for downloaded update APKs — app-private on every API
     *  level, unlike getExternalFilesDir which is world-readable pre-Q. */
    private fun apkDir(): File = File(filesDir, "update").apply { mkdirs() }

    private fun canRequestPackageInstalls(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName")
            )
            startActivity(intent)
        }
    }

    private fun installApk(path: String?): Boolean {
        if (path == null) return false
        val file = File(path)
        if (!file.exists()) return false
        val uri: Uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}

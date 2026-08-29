package dev.g0spel.zflow

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Unexported trampoline for notification taps. Tap PendingIntents land here
 * (safe: third-party apps cannot start an unexported activity), the payload
 * is handed over through process memory, and MainActivity is launched with a
 * clean intent. This keeps the exported launcher activity from accepting
 * `notificationTask` extras injected by any other app on the device.
 */
class NotificationTapActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val payload = intent?.getStringExtra("notificationTask")
        if (payload != null) pendingPayload = payload
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        )
        finish()
    }

    companion object {
        @Volatile
        var pendingPayload: String? = null
            private set

        fun clearPendingPayload() {
            pendingPayload = null
        }
    }
}

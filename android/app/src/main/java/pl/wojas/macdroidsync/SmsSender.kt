package pl.wojas.macdroidsync

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.concurrent.atomic.AtomicInteger

/**
 * Sends a message typed on the Mac and reports how it went: "sent" once every
 * part left the phone, "delivered" once every part was confirmed, or "failed".
 *
 * This app is not the default messaging app, so Android itself records the
 * sent message in the phone's database; nothing is written from here.
 */
class SmsSender(private val context: Context) {

    private val main = Handler(Looper.getMainLooper())

    fun send(address: String, text: String, report: (state: String, reason: String?) -> Unit) {
        val manager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION") SmsManager.getDefault()
        }
        if (manager == null) {
            report("failed", "this phone cannot send text messages")
            return
        }
        val parts = manager.divideMessage(text)
        val id = sequence.incrementAndGet()
        val sentAction = "$ACTION_SENT.$id"
        val deliveredAction = "$ACTION_DELIVERED.$id"
        var sentLeft = parts.size
        var deliveredLeft = parts.size
        var failed = false

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(receiverContext: Context, intent: Intent) {
                when (intent.action) {
                    sentAction -> {
                        if (failed) return
                        if (resultCode != Activity.RESULT_OK) {
                            failed = true
                            report("failed", failureReason(resultCode))
                            finish(this)
                        } else if (--sentLeft == 0) {
                            report("sent", null)
                        }
                    }
                    deliveredAction -> {
                        if (failed) return
                        if (--deliveredLeft == 0) {
                            report("delivered", null)
                            finish(this)
                        }
                    }
                }
            }
        }
        ContextCompat.registerReceiver(
            context,
            receiver,
            IntentFilter().apply { addAction(sentAction); addAction(deliveredAction) },
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        // Not every network sends delivery reports, so the receiver does not wait forever.
        main.postDelayed({ finish(receiver) }, DELIVERY_WAIT_MS)

        fun intents(action: String) = ArrayList(
            parts.indices.map { index ->
                PendingIntent.getBroadcast(
                    context,
                    id * 100 + index,
                    Intent(action).setPackage(context.packageName),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT,
                )
            }
        )
        try {
            manager.sendMultipartTextMessage(address, null, parts, intents(sentAction), intents(deliveredAction))
        } catch (error: Exception) {
            Log.w(TAG, "Sending a message failed", error)
            failed = true
            finish(receiver)
            report("failed", error.message ?: "the message could not be sent")
        }
    }

    private fun finish(receiver: BroadcastReceiver) {
        runCatching { context.unregisterReceiver(receiver) }
    }

    private fun failureReason(code: Int): String = when (code) {
        SmsManager.RESULT_ERROR_NO_SERVICE -> "the phone has no service"
        SmsManager.RESULT_ERROR_RADIO_OFF -> "the phone's radio is off"
        SmsManager.RESULT_ERROR_NULL_PDU, SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "the network refused the message"
        else -> "the message could not be sent (error $code)"
    }

    private companion object {
        private const val TAG = Prefs.TAG
        private const val ACTION_SENT = "pl.wojas.macdroidsync.SMS_SENT"
        private const val ACTION_DELIVERED = "pl.wojas.macdroidsync.SMS_DELIVERED"
        private const val DELIVERY_WAIT_MS = 10 * 60 * 1000L
        private val sequence = AtomicInteger(0)
    }
}

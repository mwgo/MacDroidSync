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
        val manager = manager()
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

    /**
     * Sends a picture, with or without words, as an MMS. The picture is made to
     * fit the carrier's size limit here, because only the phone knows it. There
     * is no delivery report for an MMS, so "sent" is the last word.
     */
    fun sendMms(address: String, text: String?, image: ByteArray, report: (state: String, reason: String?) -> Unit) {
        val manager = manager()
        if (manager == null) {
            report("failed", "this phone cannot send multimedia messages")
            return
        }
        val limit = carrierLimit(manager)
        val picture = MmsImage.fit(image, maxBytes = limit - PDU_OVERHEAD)
        if (picture == null) {
            report("failed", "the picture could not be made small enough for the carrier")
            return
        }
        val id = sequence.incrementAndGet()
        val folder = java.io.File(context.cacheDir, "mms").apply { mkdirs() }
        val file = java.io.File(folder, "send-$id.pdu")
        try {
            file.writeBytes(MmsPdu.sendRequest(address, text, picture))
        } catch (error: Exception) {
            report("failed", "the message could not be prepared")
            return
        }
        val uri = androidx.core.content.FileProvider.getUriForFile(context, "${context.packageName}.mms", file)
        // The messaging service runs in the phone process and reads the PDU from there.
        runCatching { context.grantUriPermission(PHONE_PACKAGE, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }

        val action = "$ACTION_SENT.mms.$id"
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(receiverContext: Context, intent: Intent) {
                finish(this)
                file.delete()
                if (resultCode == Activity.RESULT_OK) {
                    report("sent", null)
                } else {
                    val http = intent.getIntExtra(SmsManager.EXTRA_MMS_HTTP_STATUS, 0)
                    report("failed", if (http != 0) "the carrier refused the message (HTTP $http)" else failureReason(resultCode))
                }
            }
        }
        ContextCompat.registerReceiver(context, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)
        main.postDelayed({ finish(receiver); file.delete() }, DELIVERY_WAIT_MS)
        val sent = PendingIntent.getBroadcast(
            context,
            id * 100,
            Intent(action).setPackage(context.packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT,
        )
        try {
            manager.sendMultimediaMessage(context, uri, null, null, sent)
        } catch (error: Exception) {
            Log.w(TAG, "Sending an MMS failed", error)
            finish(receiver)
            file.delete()
            report("failed", error.message ?: "the message could not be sent")
        }
    }

    private fun manager(): SmsManager? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        context.getSystemService(SmsManager::class.java)
    } else {
        @Suppress("DEPRECATION") SmsManager.getDefault()
    }

    /** What this carrier accepts in one MMS; 300 KB when it does not say. */
    private fun carrierLimit(manager: SmsManager): Int {
        val configured = runCatching {
            @Suppress("DEPRECATION")
            manager.carrierConfigValues.getInt(SmsManager.MMS_CONFIG_MAX_MESSAGE_SIZE, 0)
        }.getOrDefault(0)
        return if (configured > 64 * 1024) configured else 300 * 1024
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
        private const val PHONE_PACKAGE = "com.android.phone"
        /** Headers, the SMIL part and the text, generously. */
        private const val PDU_OVERHEAD = 8 * 1024
        private val sequence = AtomicInteger(0)
    }
}

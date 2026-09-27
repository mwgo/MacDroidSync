package pl.wojas.macdroidsync

import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper

/**
 * Tells the service that the messaging database changed. A burst of changes, as
 * one incoming MMS causes, is reported once, [DEBOUNCE_MS] after it settles.
 */
class SmsWatcher(private val context: Context, private val onChange: () -> Unit) {

    private val main = Handler(Looper.getMainLooper())
    private val report = Runnable { onChange() }
    private var observer: ContentObserver? = null

    fun start() {
        if (observer != null) return
        val watching = object : ContentObserver(main) {
            override fun onChange(selfChange: Boolean) {
                main.removeCallbacks(report)
                main.postDelayed(report, DEBOUNCE_MS)
            }
        }
        runCatching {
            context.contentResolver.registerContentObserver(Uri.parse("content://mms-sms/"), true, watching)
            observer = watching
        }
    }

    fun stop() {
        main.removeCallbacks(report)
        observer?.let { runCatching { context.contentResolver.unregisterContentObserver(it) } }
        observer = null
    }

    private companion object {
        private const val DEBOUNCE_MS = 1_000L
    }
}

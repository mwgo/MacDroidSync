package pl.wojas.macdroidsync

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Toast

/**
 * The transparent window. Android only lets an app read from or write to the
 * clipboard while it owns the focused window, so both directions go through this
 * activity: it appears without animation, does its job as soon as it gains focus
 * and finishes immediately. On screen it is invisible.
 */
class ClipboardBridgeActivity : Activity() {

    private var handled = false
    private val fallbackHandler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)

        // A real, focusable window is what unlocks clipboard access. It is one
        // pixel of nothing in the top left corner and lives for a few frames.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
        )
        window.clearFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
        window.setGravity(Gravity.TOP or Gravity.START)
        window.setLayout(1, 1)
        window.setDimAmount(0f)
        setContentView(View(this))

        // Some skins never report focus for a translucent activity; act anyway.
        fallbackHandler.postDelayed({ perform(source = "timeout") }, FALLBACK_DELAY_MS)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        Log.d(TAG, "Bridge window focus: $hasFocus")
        if (hasFocus) perform(source = "focus")
    }

    override fun onDestroy() {
        fallbackHandler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun perform(source: String) {
        if (handled) return
        handled = true
        fallbackHandler.removeCallbacksAndMessages(null)
        Log.d(TAG, "Bridge acting on $source")

        when (intent?.getStringExtra(EXTRA_MODE)) {
            MODE_WRITE -> writeClipboard(intent.getStringExtra(EXTRA_TEXT).orEmpty())
            MODE_READ -> readClipboard()
            else -> Log.w(TAG, "Bridge started without a mode")
        }

        finish()
        overridePendingTransition(0, 0)
    }

    private fun writeClipboard(text: String) {
        if (text.isEmpty()) return
        val clipboard = getSystemService(ClipboardManager::class.java)
        if (currentClipboardText(clipboard) == text) {
            Log.d(TAG, "Clipboard already holds this value, leaving it alone")
            return
        }
        clipboard.setPrimaryClip(ClipData.newPlainText(CLIP_LABEL, text))
        Log.i(TAG, "Applied ${text.toByteArray().size} bytes from the Mac to the clipboard")
    }

    private fun readClipboard() {
        val text = currentClipboardText(getSystemService(ClipboardManager::class.java))

        if (text.isEmpty()) {
            // Without window focus Android hands out an empty clipboard, so this
            // is also what a lost focus race looks like.
            Log.w(TAG, "Clipboard read came back empty, nothing sent to the Mac")
            Toast.makeText(this, R.string.toast_clipboard_empty, Toast.LENGTH_SHORT).show()
            return
        }
        Log.i(TAG, "Sending ${text.toByteArray().size} clipboard bytes to the Mac")
        startService(
            Intent(this, SyncService::class.java)
                .setAction(SyncService.ACTION_SEND_CLIPBOARD)
                .putExtra(SyncService.EXTRA_TEXT, text)
        )
    }

    private fun currentClipboardText(clipboard: ClipboardManager): String =
        clipboard.primaryClip
            ?.takeIf { it.itemCount > 0 }
            ?.getItemAt(0)
            ?.coerceToText(this)
            ?.toString()
            .orEmpty()

    companion object {
        private const val TAG = Prefs.TAG
        private const val CLIP_LABEL = "MacDroidSync"
        private const val FALLBACK_DELAY_MS = 1_500L

        private const val EXTRA_MODE = "mode"
        private const val EXTRA_TEXT = "text"
        private const val MODE_WRITE = "write"
        private const val MODE_READ = "read"

        /** Puts text coming from the Mac on this phone's clipboard. */
        fun writeIntent(context: Context, text: String): Intent =
            Intent(context, ClipboardBridgeActivity::class.java)
                .setAction("$MODE_WRITE:${text.hashCode()}")
                .putExtra(EXTRA_MODE, MODE_WRITE)
                .putExtra(EXTRA_TEXT, text)
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_NO_ANIMATION or
                        Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS or
                        Intent.FLAG_ACTIVITY_NO_USER_ACTION
                )

        /** Reads this phone's clipboard and hands it to the service. */
        fun readIntent(context: Context): Intent =
            Intent(context, ClipboardBridgeActivity::class.java)
                .setAction(MODE_READ)
                .putExtra(EXTRA_MODE, MODE_READ)
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_NO_ANIMATION or
                        Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS
                )
    }
}

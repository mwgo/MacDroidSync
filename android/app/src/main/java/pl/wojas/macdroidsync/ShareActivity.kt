package pl.wojas.macdroidsync

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.core.content.IntentCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Target of the system share sheet.
 *
 * Shared text takes the clipboard route and ends up on the Mac's clipboard.
 * Shared files are copied into the app cache first: the read permission on a
 * `content://` URI is tied to this activity, so the copy has to happen before it
 * finishes. Once staged, [SyncService] sends them and the queue survives both a
 * missing Mac and a killed process.
 *
 * The window is transparent and stays up only for the duration of the copy.
 */
class ShareActivity : Activity() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (BuildConfig.DEBUG) describeIntent()

        val text = intent?.getStringExtra(Intent.EXTRA_TEXT)
        val uris = incomingUris()

        when {
            uris.isNotEmpty() -> stageAndSend(uris)
            !text.isNullOrBlank() -> {
                sendText(text)
                finish()
            }
            else -> {
                toast(getString(R.string.share_nothing_to_send))
                finish()
            }
        }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    /**
     * Debug builds only: what the sharing app actually handed over. Apps differ
     * wildly here (a link instead of the text, HTML next to plain text, a file
     * attachment), and this is the only way to tell without guessing. Values are
     * logged by length plus a short prefix, never in full.
     */
    private fun describeIntent() {
        val intent = intent ?: return
        Log.i(TAG, "share intent action=${intent.action} type=${intent.type}")
        intent.clipData?.let { clip ->
            Log.i(TAG, "clipData: ${clip.itemCount} item(s), description=${clip.description}")
            for (index in 0 until clip.itemCount) {
                val item = clip.getItemAt(index)
                Log.i(
                    TAG,
                    "  item $index uri=${item.uri} text=${item.text?.length ?: -1} chars" +
                        " htmlText=${item.htmlText?.length ?: -1} chars",
                )
            }
        }
        val extras = intent.extras ?: return
        for (key in extras.keySet()) {
            val value = @Suppress("DEPRECATION") extras.get(key)
            val detail = when (value) {
                is CharSequence -> "${value.length} chars: ${value.take(80)}"
                is Collection<*> -> "collection of ${value.size}"
                else -> value?.javaClass?.simpleName ?: "null"
            }
            Log.i(TAG, "  extra $key -> $detail")
        }
    }

    /**
     * EXTRA_STREAM is what the share sheet fills in, but the URI permission
     * travels with the clip data (and with the intent data for the simplest
     * senders), so all three are accepted.
     */
    private fun incomingUris(): List<Uri> {
        val intent = intent ?: return emptyList()
        val fromExtras = when (intent.action) {
            Intent.ACTION_SEND ->
                listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE ->
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                    ?.filterNotNull()
                    .orEmpty()
            else -> emptyList()
        }
        if (fromExtras.isNotEmpty()) return fromExtras

        val clip = intent.clipData
        val fromClip = (0 until (clip?.itemCount ?: 0)).mapNotNull { clip?.getItemAt(it)?.uri }
        if (fromClip.isNotEmpty()) return fromClip

        return listOfNotNull(intent.data)
    }

    private fun sendText(text: String) {
        Log.i(TAG, "Sharing ${text.length} characters of text as a clipboard")
        val intent = Intent(this, SyncService::class.java)
            .setAction(SyncService.ACTION_SEND_CLIPBOARD)
            .putExtra(SyncService.EXTRA_TEXT, text)
        runCatching { startForegroundService(intent) }
            .onFailure { Log.w(TAG, "Could not hand the text to the service", it) }
        toast(getString(R.string.share_text_sent))
    }

    /**
     * Copies every shared file while this activity still holds the URI grant and
     * only then hands the queue to the service.
     */
    private fun stageAndSend(uris: List<Uri>) {
        scope.launch {
            val outbox = Outbox(this@ShareActivity)
            val staged = withContext(Dispatchers.IO) { uris.map { outbox.enqueue(it) } }

            val accepted = staged.filterIsInstance<Outbox.Staged.Ok>()
            val tooLarge = staged.filterIsInstance<Outbox.Staged.TooLarge>()
            val failed = staged.filterIsInstance<Outbox.Staged.Failed>()

            if (accepted.isNotEmpty()) {
                val intent = Intent(this@ShareActivity, SyncService::class.java)
                    .setAction(SyncService.ACTION_SEND_FILES)
                runCatching { startForegroundService(intent) }
                    .onFailure { Log.w(TAG, "Could not start the transfer", it) }
            }

            toast(summary(accepted, tooLarge, failed))
            finish()
        }
    }

    private fun summary(
        accepted: List<Outbox.Staged.Ok>,
        tooLarge: List<Outbox.Staged.TooLarge>,
        failed: List<Outbox.Staged.Failed>,
    ): String = when {
        accepted.isEmpty() && tooLarge.isNotEmpty() ->
            getString(R.string.share_too_large, tooLarge.first().name)
        accepted.isEmpty() ->
            getString(R.string.share_failed, failed.firstOrNull()?.name.orEmpty())
        accepted.size == 1 && tooLarge.isEmpty() && failed.isEmpty() ->
            getString(R.string.share_queued_one, accepted.first().item.name)
        else ->
            getString(R.string.share_queued_many, accepted.size)
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    companion object {
        private const val TAG = Prefs.TAG
    }
}

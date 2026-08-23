package pl.wojas.macdroidsync

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.util.Log

/**
 * Rings the phone when the Mac sends a ping, so it can be found from another
 * room. It plays the phone's own ringtone in a loop together with a repeating
 * vibration, and stops after [DEFAULT_DURATION_MS] or when the user silences it.
 *
 * The ringtone plays on the ringer stream, so a phone set to silent stays silent
 * and only vibrates - the same as an incoming call.
 */
class Ringer(private val context: Context) {

    private val handler = Handler(Looper.getMainLooper())
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private var ringtone: Ringtone? = null

    /** Starts ringing, restarting the timer if it is already ringing. */
    fun start(durationMs: Long = DEFAULT_DURATION_MS) {
        stop()

        vibrate()
        ringtone = candidateUris().firstNotNullOfOrNull(::prepare)
        ringtone?.let { runCatching { it.play() }.onFailure { error -> Log.w(TAG, "Ringtone failed", error) } }
            ?: Log.w(TAG, "No ringtone available, vibrating only")

        Log.i(
            TAG,
            "Ringing for ${durationMs / 1000}s (ringer mode ${audioManager?.ringerMode ?: "unknown"}, " +
                "ring volume ${audioManager?.getStreamVolume(AudioManager.STREAM_RING) ?: -1})",
        )
        // Playback starts asynchronously; this only reports what actually happened.
        handler.postDelayed({ Log.i(TAG, "Ringtone playing: ${ringtone?.isPlaying == true}") }, START_REPORT_MS)
        handler.postDelayed(::stop, durationMs)
    }

    fun stop() {
        handler.removeCallbacksAndMessages(null)
        ringtone?.let { current ->
            runCatching { if (current.isPlaying) current.stop() }
        }
        ringtone = null
        runCatching { vibrator()?.cancel() }
    }

    /**
     * The indirect system URI comes first: it always resolves to whatever the
     * user picked, without this app needing access to the underlying media file.
     */
    private fun candidateUris(): List<Uri> = listOfNotNull(
        Settings.System.DEFAULT_RINGTONE_URI,
        RingtoneManager.getActualDefaultRingtoneUri(context, RingtoneManager.TYPE_RINGTONE),
        Settings.System.DEFAULT_NOTIFICATION_URI,
    )

    private fun prepare(uri: Uri): Ringtone? = runCatching {
        val candidate = RingtoneManager.getRingtone(context, uri) ?: return@runCatching null
        candidate.audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        candidate.isLooping = true
        Log.i(TAG, "Ringing with $uri")
        candidate
    }.onFailure { Log.w(TAG, "Could not prepare $uri", it) }.getOrNull()

    private fun vibrate() {
        val effect = VibrationEffect.createWaveform(VIBRATION_PATTERN, VIBRATION_REPEAT_FROM)
        runCatching { vibrator()?.vibrate(effect) }
            .onFailure { Log.w(TAG, "Could not vibrate", it) }
    }

    private fun vibrator(): Vibrator? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Vibrator::class.java)
        }

    companion object {
        private const val TAG = Prefs.TAG
        const val DEFAULT_DURATION_MS = 20_000L
        private const val START_REPORT_MS = 500L

        /** Wait, buzz, pause - repeated until cancelled. */
        private val VIBRATION_PATTERN = longArrayOf(0, 700, 500)
        private const val VIBRATION_REPEAT_FROM = 0
    }
}

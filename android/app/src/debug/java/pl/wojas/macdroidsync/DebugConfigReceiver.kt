package pl.wojas.macdroidsync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Debug builds only: configures pairing and connection settings from adb so the
 * end to end flow can be exercised without touching the screen.
 *
 *   adb shell am broadcast -n pl.wojas.macdroidsync/.DebugConfigReceiver \
 *       -a pl.wojas.macdroidsync.DEBUG_CONFIG \
 *       --es code ABCD-EFGH-JKLM-NPQR --es host 10.0.2.2 --ei port 47831 --ez enabled true
 *
 * The presence beacon has its own flag, so the auto lock can be exercised
 * without the screen:
 *
 *   ... --ez beacon true
 *
 * And it can ask the Mac to lock its screen, the same thing the Lock Now button
 * and the notification action do:
 *
 *   ... --ez lock true
 *
 * It can also open the transparent clipboard window, which is otherwise only
 * reachable from the notification action:
 *
 *   ... --es bridge read
 *   ... --es bridge write --es text "hello"
 */
class DebugConfigReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        intent.getStringExtra("bridge")?.let { mode ->
            val bridge = if (mode == "read") {
                ClipboardBridgeActivity.readIntent(context)
            } else {
                ClipboardBridgeActivity.writeIntent(context, intent.getStringExtra("text").orEmpty())
            }
            Log.i(Prefs.TAG, "Debug bridge: $mode")
            context.startActivity(bridge)
            return
        }

        if (intent.getBooleanExtra("lock", false)) {
            Log.i(Prefs.TAG, "Debug: asking the Mac to lock")
            SyncService.start(context, SyncService.ACTION_LOCK_MAC)
            return
        }

        val prefs = Prefs(context)
        intent.getStringExtra("code")?.let { prefs.pairingCode = it }
        intent.getStringExtra("host")?.let { prefs.manualHost = it }
        if (intent.hasExtra("port")) prefs.port = intent.getIntExtra("port", Wire.DEFAULT_PORT)
        if (intent.hasExtra("enabled")) prefs.syncEnabled = intent.getBooleanExtra("enabled", false)
        if (intent.hasExtra("beacon")) prefs.beaconEnabled = intent.getBooleanExtra("beacon", false)

        Log.i(
            Prefs.TAG,
            "Debug config: host='${prefs.manualHost}' port=${prefs.port} " +
                "enabled=${prefs.syncEnabled} beacon=${prefs.beaconEnabled} " +
                "codeLength=${prefs.pairingCode.length}",
        )
        if (prefs.syncEnabled) {
            SyncService.start(context, SyncService.ACTION_RECONNECT)
        } else {
            // ACTION_STOP ends the sync; the service stays for the beacon.
            SyncService.stop(context)
        }
    }
}

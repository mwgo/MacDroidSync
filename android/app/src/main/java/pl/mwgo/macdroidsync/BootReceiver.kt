package pl.mwgo.macdroidsync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Brings the sync back after a reboot or an update of this app, both of which
 * stop it, but only if the user had it enabled. That also covers the presence
 * beacon, which only broadcasts while the sync is on. The background scan for
 * the camera ends the same way and is started again whatever the sync.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        FujifilmCamera.watch(context)
        if (!Prefs(context).syncEnabled) return
        Log.i(Prefs.TAG, "${intent.action}, starting the sync service")
        SyncService.start(context)
    }
}

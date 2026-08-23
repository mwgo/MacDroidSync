package pl.wojas.macdroidsync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** Brings the sync back after a reboot, but only if the user had it enabled. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!Prefs(context).syncEnabled) return
        Log.i(Prefs.TAG, "Boot completed, starting the sync service")
        SyncService.start(context)
    }
}

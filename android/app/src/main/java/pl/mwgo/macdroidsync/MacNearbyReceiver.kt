package pl.mwgo.macdroidsync

import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Results of the scan [MacScanner] left with the system. Starting the service
 * from here is allowed only with the Mac linked as the companion device.
 */
class MacNearbyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val error = intent.getIntExtra(BluetoothLeScanner.EXTRA_ERROR_CODE, 0)
        if (error != 0) {
            Log.w(Prefs.TAG, "Scan for the Mac failed: $error")
            return
        }
        val callback = intent.getIntExtra(BluetoothLeScanner.EXTRA_CALLBACK_TYPE, ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
        if (callback == ScanSettings.CALLBACK_TYPE_MATCH_LOST) {
            Log.i(Prefs.TAG, "The Mac is out of range")
            MacScanner.markLost(context)
            return
        }
        appeared(context, inRange = callback == ScanSettings.CALLBACK_TYPE_FIRST_MATCH)
    }

    companion object {
        /** The Mac was seen, by this scan or by the system's (MacPresenceService). */
        fun appeared(context: Context, inRange: Boolean) {
            MacScanner.markSeen(context, inRange)
            if (SyncService.running != null || !Prefs(context).syncEnabled) return
            Log.i(Prefs.TAG, "The Mac is in range again, starting the sync")
            SyncService.start(context)
        }
    }
}

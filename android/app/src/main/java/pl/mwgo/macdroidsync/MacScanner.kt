package pl.mwgo.macdroidsync

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.ParcelUuid
import android.util.Log

/**
 * Watches for the advertisement of the Mac, see PROTOCOL.md section 7.
 *
 * The scan is handed to the system with a PendingIntent, so it keeps running in
 * the controller while this app does not run at all. That is what lets the
 * service stop while the Mac is out of range, together with its notification:
 * [MacNearbyReceiver] starts it again once the Mac is seen.
 */
class MacScanner(private val context: Context, private val prefs: Prefs) {

    private val adapter
        get() = context.getSystemService(BluetoothManager::class.java)?.adapter

    /**
     * Whether a missing advertisement can be read as a Mac out of range. With a
     * typed in host the Mac may well be reached from afar.
     */
    val isUsable: Boolean
        get() = Permissions.hasScan(context) && MacCompanion.isLinked(context) &&
            adapter?.isEnabled == true && prefs.manualHost.isEmpty()

    @SuppressLint("MissingPermission")
    fun watch() {
        if (!Permissions.hasScan(context)) return
        val code = prefs.pairingCode
        val scanner = adapter?.takeIf { it.isEnabled }?.bluetoothLeScanner
        if (code.isBlank() || scanner == null) return
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(PresenceBeacon.macServiceUuid(code)))
            .build()
        // Found and lost, once each, where the controller can tell; otherwise
        // every packet, and the time of the last one is all there is to go by.
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
            .apply {
                if (adapter?.isOffloadedFilteringSupported == true) {
                    setCallbackType(ScanSettings.CALLBACK_TYPE_FIRST_MATCH or ScanSettings.CALLBACK_TYPE_MATCH_LOST)
                }
            }
            .build()
        runCatching {
            scanner.stopScan(pendingIntent())
            scanner.startScan(listOf(filter), settings, pendingIntent())
        }
            .onSuccess { Log.i(TAG, "Watching for the Mac's advertisement") }
            .onFailure { Log.w(TAG, "Could not watch for the Mac", it) }
    }

    @SuppressLint("MissingPermission")
    fun unwatch() {
        if (!Permissions.hasScan(context)) return
        runCatching { adapter?.bluetoothLeScanner?.stopScan(pendingIntent()) }
    }

    /** Mutable, because the system adds the scan results to it. */
    private fun pendingIntent(): PendingIntent = PendingIntent.getBroadcast(
        context,
        0,
        Intent(context, MacNearbyReceiver::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0),
    )

    companion object {
        private const val TAG = Prefs.TAG
        private const val STORE = "mac-range"
        private const val KEY_SEEN_AT = "seenAt"
        private const val KEY_IN_RANGE = "inRange"
        private const val KEY_ADDRESS = "address"
        /** Writing every packet would wear the flash for nothing. */
        private const val MARK_EVERY_MS = 30_000L

        /**
         * When the Mac was last seen or lost, 0 when never, and whether it is in
         * range now, as far as the controller reports it. Kept out of the
         * encrypted preferences: none of it is a secret.
         */
        fun seenAt(context: Context): Long = store(context).getLong(KEY_SEEN_AT, 0)

        /** The Mac's Bluetooth address as it said in hello-ack, null until then. */
        fun address(context: Context): String? = store(context).getString(KEY_ADDRESS, null)

        fun rememberAddress(context: Context, address: String) {
            if (address != address(context)) store(context).edit().putString(KEY_ADDRESS, address).apply()
        }

        fun inRange(context: Context): Boolean = store(context).getBoolean(KEY_IN_RANGE, false)

        /** [inRange] only when the controller will also say once it is lost. */
        fun markSeen(context: Context, inRange: Boolean, now: Long = System.currentTimeMillis()) {
            if (!inRange && now - seenAt(context) < MARK_EVERY_MS) return
            store(context).edit().putLong(KEY_SEEN_AT, now).putBoolean(KEY_IN_RANGE, inRange).apply()
        }

        fun markLost(context: Context, now: Long = System.currentTimeMillis()) {
            store(context).edit().putLong(KEY_SEEN_AT, now).putBoolean(KEY_IN_RANGE, false).apply()
        }

        private fun store(context: Context) = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
    }
}

/** When the service may stop, waiting for the Mac to come back in range. */
object MacRange {
    const val AWAY_MS = 2 * 60_000L

    /**
     * A Mac never seen may be one that does not advertise at all, so it would
     * never wake this phone again.
     */
    fun shouldSleep(now: Long, seenAt: Long, inRange: Boolean, usable: Boolean): Boolean =
        usable && seenAt > 0 && !inRange && now - seenAt > AWAY_MS
}

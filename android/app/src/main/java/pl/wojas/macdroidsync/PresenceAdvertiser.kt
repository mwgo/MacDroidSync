package pl.wojas.macdroidsync

import android.app.AlarmManager
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Broadcasts the presence beacon so the Mac can tell how far away this phone is.
 *
 * Rather than a connection, this is plain BLE advertising: the packet is handed
 * to the controller, which repeats it without waking the application, and the
 * Mac averages the signal strength it measures. The token inside the packet is
 * only valid for one 30 second slot, so the advertisement is rebuilt at every
 * slot boundary.
 *
 * That the controller needs no help from the CPU is what makes this feature work
 * at all, and also what makes it subtle: while the phone is suspended the packets
 * keep going out with whatever token was last published. The handler below only
 * runs when the CPU does, so it is backed by an alarm that survives Doze - see
 * [scheduleWake]. The Mac tolerates a wide range of slots for the same reason.
 *
 * Everything is best effort and loud in the log: no permission, no Bluetooth, no
 * pairing code or a radio that refuses to advertise all end up as "no beacon",
 * never as a crash. A missing beacon is safe by design - the Mac never locks a
 * screen for a phone it has not seen.
 */
class PresenceAdvertiser(private val context: Context) {

    private val handler = Handler(Looper.getMainLooper())
    private var pairingCode: String = ""
    private var isStarted = false
    /** Kept so stopping never has to look the adapter up again. */
    private var activeAdvertiser: android.bluetooth.le.BluetoothLeAdvertiser? = null

    @Volatile
    var isAdvertising: Boolean = false
        private set

    private val callback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            isAdvertising = true
        }

        override fun onStartFailure(errorCode: Int) {
            isAdvertising = false
            Log.w(TAG, "Advertising the presence beacon failed: ${describe(errorCode)}")
        }
    }

    private val alarms = context.getSystemService(AlarmManager::class.java)

    /**
     * The alarm that republishes the token, addressed to this package only. It is
     * immutable and carries no extras: the fact that it arrived is the whole
     * message.
     */
    private val wakeIntent: PendingIntent by lazy {
        PendingIntent.getBroadcast(
            context,
            0,
            Intent(ACTION_WAKE).setPackage(context.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /**
     * Bluetooth can be switched off and on again underneath us, and the wake
     * alarm is the only thing that reaches this object through a suspended CPU.
     */
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                ACTION_WAKE -> refresh()
                // Reached on Android 11 and older only. From 12 on this broadcast
                // is guarded by BLUETOOTH_CONNECT, which this app deliberately
                // does not hold - it never connects to anything, it only
                // advertises - so the branch below simply never runs there.
                // Confirmed on Android 16: switching Bluetooth off and on again
                // delivered nothing at all.
                //
                // Kept rather than deleted, because minSdk is 28 and it does work
                // on those releases. Losing it costs nothing on newer ones:
                // [refresh] reschedules itself whether or not the radio was
                // available, so the next 30 second tick re-reads the adapter and
                // picks the beacon back up within one slot. That poll is what
                // actually recovers on a modern phone - measured at about ten
                // seconds from switching Bluetooth back on.
                BluetoothAdapter.ACTION_STATE_CHANGED -> when (
                    intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                ) {
                    BluetoothAdapter.STATE_ON -> {
                        Log.i(TAG, "Bluetooth came back, restarting the presence beacon")
                        refresh()
                    }
                    BluetoothAdapter.STATE_TURNING_OFF -> {
                        isAdvertising = false
                    }
                }
            }
        }
    }

    // region Lifecycle

    fun start(pairingCode: String) {
        if (pairingCode.isBlank()) {
            Log.i(TAG, "No pairing code, the presence beacon stays off")
            stop()
            return
        }
        // Called again on every service command, so a beacon that is already
        // broadcasting the right thing is left alone instead of restarted.
        val unchanged = isStarted && isAdvertising && this.pairingCode == pairingCode
        this.pairingCode = pairingCode
        if (unchanged) return

        if (!isStarted) {
            isStarted = true
            val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
            filter.addAction(ACTION_WAKE)
            ContextCompat.registerReceiver(
                context,
                receiver,
                filter,
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
        }
        refresh()
    }

    fun stop() {
        handler.removeCallbacksAndMessages(null)
        runCatching { alarms?.cancel(wakeIntent) }
        stopAdvertising()
        if (isStarted) {
            isStarted = false
            runCatching { context.unregisterReceiver(receiver) }
        }
    }

    // endregion

    /**
     * Rebuilds the advertisement for the current slot and schedules the next
     * rebuild for the moment that slot ends. Restarting is what publishes a new
     * payload; it costs a couple of controller commands and the gap is far too
     * short for the Mac, which tolerates 15 seconds of silence.
     *
     * A radio that cannot be reached right now must not end the story: the
     * scheduling at the bottom happens either way, so the next slot tries again.
     * Returning early here used to leave the beacon stopped for good, because the
     * advertisement had already been torn down on the way in.
     */
    private fun refresh() {
        stopAdvertising()
        if (!isStarted) return

        val advertiser = advertiserOrNull()
        if (advertiser == null) {
            scheduleNextSlot()
            scheduleWake()
            return
        }
        val payload = PresenceBeacon.currentPayload(pairingCode)
        val data = AdvertiseData.Builder()
            // The name would push the packet past the 31 byte limit.
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceUuid(ParcelUuid(PresenceBeacon.serviceUuid(pairingCode)))
            .addManufacturerData(PresenceBeacon.MANUFACTURER_ID, payload)
            .build()
        val settings = AdvertiseSettings.Builder()
            // 250 ms between packets: the Mac needs a steady stream to average,
            // and its own scan is duty cycled, so a one second interval would
            // arrive far more sparsely than it sounds.
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            // A beacon, not a service: nothing may connect to this.
            .setConnectable(false)
            .setTimeout(0)
            .build()

        try {
            advertiser.startAdvertising(settings, data, callback)
            activeAdvertiser = advertiser
            Log.i(TAG, "Presence beacon advertising as ${PresenceBeacon.serviceUuid(pairingCode)}")
        } catch (error: Exception) {
            // A missing runtime permission arrives as a SecurityException.
            Log.w(TAG, "Could not start the presence beacon", error)
        }

        scheduleNextSlot()
        scheduleWake()
    }

    private fun scheduleNextSlot() {
        val slotMillis = PresenceBeacon.SLOT_SECONDS * 1000
        val delay = slotMillis - (System.currentTimeMillis() % slotMillis)
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({ refresh() }, delay)
    }

    /**
     * The safety net under [scheduleNextSlot]. A handler is scheduled against
     * uptime and holds no wake lock, so it simply does not run while the phone is
     * suspended - measured at 99 seconds of silence on a Galaxy S25 in light
     * Doze, and far longer once deep idle sets in. The controller carries on
     * broadcasting the token published before the suspend, so the beacon looks
     * healthy from the outside while the Mac quietly rejects every packet.
     *
     * Inexact and "allow while idle" on purpose. Doze rate limits an alarm like
     * this to roughly one firing every nine minutes per app, which is the cadence
     * wanted here anyway, and unlike an exact alarm it needs no permission the
     * user could take away.
     *
     * Inexact also means the system answers with a window rather than an instant:
     * asked for ten minutes, `dumpsys alarm` reported a latest delivery of about
     * seventeen. The Mac's slot tolerance is sized against that worst case, not
     * against the ten minutes asked for here.
     *
     * Rescheduled on every [refresh], so while the handler is ticking the alarm
     * is pushed forward and never fires. It is a watchdog: it only ever goes off
     * after the phone really has been suspended, which costs no battery at all
     * the rest of the time.
     */
    private fun scheduleWake() {
        val manager = alarms ?: return
        runCatching {
            manager.setAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                System.currentTimeMillis() + WAKE_INTERVAL_MS,
                wakeIntent,
            )
        }.onFailure { Log.w(TAG, "Could not schedule the presence beacon wake up", it) }
    }

    private fun stopAdvertising() {
        val advertiser = activeAdvertiser ?: return
        activeAdvertiser = null
        isAdvertising = false
        runCatching { advertiser.stopAdvertising(callback) }
            .onFailure { Log.w(TAG, "Could not stop the presence beacon", it) }
    }

    private fun advertiserOrNull(): android.bluetooth.le.BluetoothLeAdvertiser? {
        if (!hasPermission()) {
            Log.i(TAG, "Nearby devices permission missing, the presence beacon stays off")
            return null
        }
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
        if (adapter == null || !adapter.isEnabled) {
            Log.i(TAG, "Bluetooth is off, the presence beacon stays off")
            return null
        }
        if (!adapter.isMultipleAdvertisementSupported) {
            Log.w(TAG, "This phone cannot advertise over Bluetooth LE")
            return null
        }
        return adapter.bluetoothLeAdvertiser
    }

    fun hasPermission(): Boolean = Permissions.hasNearby(context)

    private fun describe(errorCode: Int): String = when (errorCode) {
        AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE ->
            "the advertisement does not fit in 31 bytes"
        AdvertiseCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS ->
            "too many advertisers on this phone"
        AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED -> "already advertising"
        AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR -> "internal Bluetooth error"
        AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED ->
            "advertising is not supported here"
        else -> "error $errorCode"
    }

    companion object {
        private const val TAG = Prefs.TAG
        private const val ACTION_WAKE = "pl.wojas.macdroidsync.BEACON_WAKE"
        /**
         * Ten minutes, just above the nine that Doze allows, so a firing is never
         * dropped for being too eager.
         */
        private const val WAKE_INTERVAL_MS = 10 * 60 * 1000L
    }
}

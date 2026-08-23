package pl.wojas.macdroidsync

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

    /** Bluetooth can be switched off and on again underneath us. */
    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
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
            ContextCompat.registerReceiver(
                context,
                adapterReceiver,
                IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
        }
        refresh()
    }

    fun stop() {
        handler.removeCallbacksAndMessages(null)
        stopAdvertising()
        if (isStarted) {
            isStarted = false
            runCatching { context.unregisterReceiver(adapterReceiver) }
        }
    }

    // endregion

    /**
     * Rebuilds the advertisement for the current slot and schedules the next
     * rebuild for the moment that slot ends. Restarting is what publishes a new
     * payload; it costs a couple of controller commands and the gap is far too
     * short for the Mac, which tolerates 15 seconds of silence.
     */
    private fun refresh() {
        stopAdvertising()
        if (!isStarted) return

        val advertiser = advertiserOrNull() ?: return
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
    }

    private fun scheduleNextSlot() {
        val slotMillis = PresenceBeacon.SLOT_SECONDS * 1000
        val delay = slotMillis - (System.currentTimeMillis() % slotMillis)
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({ refresh() }, delay)
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
    }
}

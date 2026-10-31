package pl.mwgo.macdroidsync

import android.annotation.SuppressLint
import android.app.Service
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.text.DateFormat
import java.util.Date
import java.util.TimeZone

/**
 * Keeps the camera's location and clock right while it is switched on: connects
 * to it over Bluetooth LE and, every configured interval, writes the time and a
 * fresh location fix. Runs only while the camera is around; without it there is
 * no connection, no write and no location request.
 *
 * The camera is told the same interval, and also asks for a location or the
 * time by notification; those are answered with what is already at hand.
 */
@SuppressLint("MissingPermission")
class CameraLinkService : Service() {

    private val main = Handler(Looper.getMainLooper())
    private lateinit var prefs: Prefs
    private var gatt: BluetoothGatt? = null
    private var connected = false
    private var attempts = 0
    private var lastFix: Location? = null
    private var lastSync: Long = 0
    private var lastSyncHadLocation = false
    private var locating: CancellationSignal? = null

    private val queue = ArrayDeque<() -> Boolean>()
    private var busy = false
    private val stuck = Runnable { Log.w(Prefs.TAG, "Camera did not answer, moving on"); done() }
    private val tick = Runnable { sync() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        startForegroundCompat(
            when {
                lastSync > 0 -> status()
                connected -> getString(R.string.camera_sync_waiting)
                else -> getString(R.string.camera_sync_connecting)
            }
        )
        if (gatt == null) connect()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        locating?.cancel()
        gatt?.run { disconnect(); close() }
        gatt = null
        running = false
        // The camera may still be on: the plain notification takes over the same id.
        stopForeground(STOP_FOREGROUND_DETACH)
        FujifilmCamera.refresh(this, startLink = false)
        super.onDestroy()
    }

    private fun connect() {
        val device = getSystemService(BluetoothManager::class.java)?.adapter
            ?.runCatching { getRemoteDevice(prefs.cameraAddress) }?.getOrNull()
        if (device == null) {
            stopSelf()
            return
        }
        attempts++
        Log.i(Prefs.TAG, "Connecting to ${prefs.cameraName} for location and time, attempt $attempts")
        gatt = device.connectGatt(this, false, callback, BluetoothDevice.TRANSPORT_LE)
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    connected = true
                    attempts = 0
                    gatt.requestMtu(MTU)
                } else {
                    lost(status)
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            main.post { gatt.discoverServices() }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            main.post { if (status == BluetoothGatt.GATT_SUCCESS) prepare() else lost(status) }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: android.bluetooth.BluetoothGattDescriptor, status: Int) {
            main.post { done() }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            main.post {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    Log.w(Prefs.TAG, "Camera refused ${characteristic.uuid}: $status")
                }
                done()
            }
        }

        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            main.post { read(characteristic, value) }
        }

        @Deprecated("Before Android 13")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            @Suppress("DEPRECATION") val value = characteristic.value ?: ByteArray(0)
            main.post { read(characteristic, value) }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            main.post { asked(characteristic) }
        }

        @Deprecated("Before Android 13")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            main.post { asked(characteristic) }
        }
    }

    /** Subscribes to the camera's requests, tells it the interval, then the first sync. */
    private fun prepare() {
        Log.i(Prefs.TAG, "Connected to ${prefs.cameraName}, sending location and time every ${prefs.cameraGeoInterval} s")
        characteristic(FujifilmGeo.LOCATION_SYNC_STATE)?.let { enqueue { subscribe(it) } }
        characteristic(FujifilmGeo.DATE_SYNC_STATE)?.let { enqueue { subscribe(it) } }
        characteristic(FujifilmGeo.LOCATION_SYNC_SETTING)?.let { enqueue { gatt?.readCharacteristic(it) == true } }
        characteristic(FujifilmGeo.LOCATION_SYNC_CYCLE)?.let {
            enqueue { write(it, FujifilmGeo.interval(prefs.cameraGeoInterval)) }
        }
        sync()
    }

    private fun read(characteristic: BluetoothGattCharacteristic, value: ByteArray) {
        if (characteristic.uuid == FujifilmGeo.LOCATION_SYNC_SETTING && value.firstOrNull()?.toInt() == 0) {
            // Off in the camera, it would ignore what is sent; this is the switch XApp turns on.
            Log.i(Prefs.TAG, "Turning the camera's location sync on")
            queue.addFirst { write(characteristic, byteArrayOf(1, 0)) }
        }
        done()
    }

    private fun asked(characteristic: BluetoothGattCharacteristic) {
        when (characteristic.uuid) {
            FujifilmGeo.DATE_SYNC_STATE -> sendTime()
            FujifilmGeo.LOCATION_SYNC_STATE -> lastFix?.takeIf { fresh(it) }?.let { sendLocation(it) }
        }
    }

    /** One round: the time at once, the location once a fix arrives. */
    private fun sync() {
        main.removeCallbacks(tick)
        if (!connected) return
        sendTime()
        locate { fix ->
            if (fix != null) {
                lastFix = fix
                sendLocation(fix)
            }
            lastSync = System.currentTimeMillis()
            lastSyncHadLocation = fix != null
            startForegroundCompat(status())
        }
        main.postDelayed(tick, prefs.cameraGeoInterval * 1000L)
    }

    private fun sendTime() {
        val now = System.currentTimeMillis()
        val zone = TimeZone.getDefault()
        val utc = characteristic(FujifilmGeo.UTC_AND_TIMEZONE)
        if (utc != null) {
            enqueue { write(utc, FujifilmGeo.utcAndTimezone(now, zone)) }
        } else {
            characteristic(FujifilmGeo.DATE_TIME)?.let { enqueue { write(it, FujifilmGeo.dateTime(now, zone)) } }
        }
    }

    private fun sendLocation(fix: Location) {
        val target = characteristic(FujifilmGeo.LOCATION_AND_SPEED) ?: return
        val bytes = FujifilmGeo.location(fix.latitude, fix.longitude, fix.altitude, fix.speed, fix.time)
        enqueue { write(target, bytes) }
    }

    private fun fresh(fix: Location): Boolean =
        System.currentTimeMillis() - fix.time <= prefs.cameraGeoInterval * 1000L + LOCATE_TIMEOUT_MS

    /**
     * A fresh fix, or null without the permission, with location turned off, or
     * when nothing accurate enough came in time.
     */
    private fun locate(result: (Location?) -> Unit) {
        val manager = getSystemService(LocationManager::class.java)
        if (!Permissions.hasCameraLocation(this) || manager == null || !manager.isLocationEnabled) {
            result(null)
            return
        }
        val provider = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && manager.hasProvider(LocationManager.FUSED_PROVIDER) ->
                LocationManager.FUSED_PROVIDER
            manager.isProviderEnabled(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
            else -> LocationManager.NETWORK_PROVIDER
        }
        locating?.cancel()
        val signal = CancellationSignal().also { locating = it }
        var answered = false
        val finish = { fix: Location? ->
            if (!answered) {
                answered = true
                main.removeCallbacksAndMessages(signal)
                val good = fix?.takeIf { it.hasAccuracy() && it.accuracy <= FujifilmGeo.MAX_ACCURACY_M }
                if (fix != null && good == null) Log.i(Prefs.TAG, "Location too rough for the camera: ${fix.accuracy} m")
                result(good)
            }
        }
        main.postAtTime({ signal.cancel(); finish(null) }, signal, android.os.SystemClock.uptimeMillis() + LOCATE_TIMEOUT_MS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val request = android.location.LocationRequest.Builder(0)
                .setQuality(android.location.LocationRequest.QUALITY_HIGH_ACCURACY)
                .setDurationMillis(LOCATE_TIMEOUT_MS)
                .build()
            manager.getCurrentLocation(provider, request, signal, mainExecutor) { main.post { finish(it) } }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            manager.getCurrentLocation(provider, signal, mainExecutor) { main.post { finish(it) } }
        } else {
            @Suppress("DEPRECATION")
            manager.requestSingleUpdate(provider, { main.post { finish(it) } }, Looper.getMainLooper())
        }
    }

    private fun lost(status: Int) {
        val wasConnected = connected
        connected = false
        main.removeCallbacks(tick)
        locating?.cancel()
        queue.clear()
        busy = false
        gatt?.close()
        gatt = null
        Log.i(Prefs.TAG, "Camera link closed ($status)")
        // A failed first attempt is common with Bluetooth LE; a camera still
        // advertising gets a few more before this gives up.
        if (!wasConnected && attempts < MAX_ATTEMPTS && prefs.cameraNearby) {
            main.postDelayed({ connect() }, RETRY_DELAY_MS)
        } else {
            stopSelf()
        }
    }

    // region One GATT operation at a time

    private fun enqueue(operation: () -> Boolean) {
        queue.addLast(operation)
        if (!busy) next()
    }

    private fun next() {
        while (true) {
            val operation = queue.removeFirstOrNull() ?: run { busy = false; return }
            busy = true
            if (runCatching(operation).getOrDefault(false)) {
                main.postDelayed(stuck, OPERATION_TIMEOUT_MS)
                return
            }
        }
    }

    private fun done() {
        main.removeCallbacks(stuck)
        busy = false
        next()
    }

    private fun characteristic(uuid: java.util.UUID): BluetoothGattCharacteristic? =
        gatt?.services?.firstNotNullOfOrNull { it.getCharacteristic(uuid) }

    private fun write(characteristic: BluetoothGattCharacteristic, value: ByteArray): Boolean {
        val gatt = gatt ?: return false
        val type = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(characteristic, value, type) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            characteristic.run { writeType = type; setValue(value) }
            @Suppress("DEPRECATION") gatt.writeCharacteristic(characteristic)
        }
    }

    private fun subscribe(characteristic: BluetoothGattCharacteristic): Boolean {
        val gatt = gatt ?: return false
        val descriptor = characteristic.getDescriptor(FujifilmGeo.CCCD) ?: return false
        gatt.setCharacteristicNotification(characteristic, true)
        val indicate = characteristic.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0
        val value = if (indicate) byteArrayOf(2, 0) else byteArrayOf(1, 0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(descriptor, value) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION") descriptor.setValue(value)
            @Suppress("DEPRECATION") gatt.writeDescriptor(descriptor)
        }
    }

    // endregion

    private fun status(): String {
        val time = DateFormat.getTimeInstance(DateFormat.MEDIUM).format(Date(lastSync))
        return getString(
            if (lastSyncHadLocation) R.string.camera_sync_done else R.string.camera_sync_time_only,
            time,
        )
    }

    private fun startForegroundCompat(text: String) {
        val notification = FujifilmCamera.notification(this, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(FujifilmCamera.NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(FujifilmCamera.NOTIFICATION_ID, notification)
        }
    }

    companion object {
        private const val ACTION_STOP = "pl.mwgo.macdroidsync.CAMERA_LINK_STOP"
        private const val MTU = 185
        private const val MAX_ATTEMPTS = 3
        private const val RETRY_DELAY_MS = 5_000L
        private const val OPERATION_TIMEOUT_MS = 5_000L
        private const val LOCATE_TIMEOUT_MS = 30_000L

        @Volatile
        var running = false
            private set

        fun start(context: Context) {
            runCatching { context.startForegroundService(Intent(context, CameraLinkService::class.java)) }
                .onFailure { Log.w(Prefs.TAG, "Could not start the camera link", it) }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CameraLinkService::class.java))
        }
    }
}

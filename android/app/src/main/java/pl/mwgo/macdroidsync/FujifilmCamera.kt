package pl.mwgo.macdroidsync

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.NotificationCompat

/** Which paired devices are Fujifilm cameras, by the names the cameras give themselves. */
object FujifilmNames {
    // X-E5, X-T50, X-S20, X-H2S, X-Pro3, X-M5, X100VI, GFX100S II, ...
    private val pattern = Regex("^(X-[A-Z]|X\\d|GFX)", RegexOption.IGNORE_CASE)

    fun looksLikeCamera(name: String?): Boolean = name != null && pattern.containsMatchIn(name.trim())
}

/**
 * Tells when the chosen Fujifilm camera is on, with or without FUJIFILM XApp.
 *
 * A camera that is switched on advertises over Bluetooth LE, which is what XApp
 * scans for before it connects. A background scan matching only the camera's
 * address reports here when the advertising starts and when it stops, even with
 * nothing of this app running. While XApp is connected the camera may stop
 * advertising, so the link itself counts as well, through the system's connect
 * and disconnect broadcasts. Nothing here ever connects to the camera.
 */
object FujifilmCamera {

    fun hasBluetooth(context: Context): Boolean =
        context.getSystemService(BluetoothManager::class.java)?.adapter != null

    /** Paired devices, cameras first, then by name. Empty without the permission. */
    @SuppressLint("MissingPermission")
    fun pairedDevices(context: Context): List<BluetoothDevice> {
        if (!Permissions.hasBluetoothConnect(context)) return emptyList()
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return emptyList()
        val bonded = runCatching { adapter.bondedDevices.orEmpty() }.getOrDefault(emptySet())
        return bonded.sortedWith(
            compareByDescending<BluetoothDevice> { FujifilmNames.looksLikeCamera(name(it)) }
                .thenBy { name(it)?.lowercase() ?: it.address }
        )
    }

    @SuppressLint("MissingPermission")
    fun name(device: BluetoothDevice): String? = runCatching { device.name }.getOrNull()

    /** Whether the chosen camera has a Bluetooth LE link to this phone right now. */
    @SuppressLint("MissingPermission")
    fun isConnected(context: Context): Boolean {
        val address = Prefs(context).cameraAddress
        if (address.isEmpty() || !Permissions.hasBluetoothConnect(context)) return false
        val manager = context.getSystemService(BluetoothManager::class.java) ?: return false
        val connected = runCatching { manager.getConnectedDevices(BluetoothProfile.GATT) }.getOrDefault(emptyList())
        return connected.any { it.address.equals(address, ignoreCase = true) }
    }

    fun isOn(context: Context): Boolean = Prefs(context).cameraNearby || isConnected(context)

    /** Brings the notification in line with what is known about the camera now. */
    fun refresh(context: Context) {
        if (isWatched(context) && isOn(context)) show(context) else hide(context)
    }

    /**
     * Starts the background scan for the chosen camera, or stops it when the
     * feature is off. The system keeps it across the app's death but not across
     * a reboot or an update, which call this again.
     */
    @SuppressLint("MissingPermission")
    fun watch(context: Context) {
        val prefs = Prefs(context)
        val scanner = scanner(context)
        val intent = scanIntent(context)
        if (scanner != null && Permissions.hasBluetoothScan(context)) {
            runCatching { scanner.stopScan(intent) }
        }
        prefs.cameraNearby = false
        if (isWatched(context) && scanner != null && Permissions.hasBluetoothScan(context)) {
            val filter = ScanFilter.Builder().setDeviceAddress(prefs.cameraAddress.uppercase()).build()
            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
                .setCallbackType(ScanSettings.CALLBACK_TYPE_FIRST_MATCH or ScanSettings.CALLBACK_TYPE_MATCH_LOST)
                .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
                .setNumOfMatches(ScanSettings.MATCH_NUM_ONE_ADVERTISEMENT)
                .build()
            val result = runCatching { scanner.startScan(listOf(filter), settings, intent) }
            Log.i(Prefs.TAG, "Watching for ${prefs.cameraName} ${prefs.cameraAddress}: ${result.getOrNull() ?: result.exceptionOrNull()}")
        }
        refresh(context)
    }

    private fun scanner(context: Context): BluetoothLeScanner? =
        context.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeScanner

    private fun scanIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        REQUEST_SCAN,
        Intent(context, FujifilmCameraReceiver::class.java).setAction(ACTION_SCAN),
        // Mutable because the system adds the scan results to it.
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
    )

    fun isWatched(context: Context): Boolean {
        val prefs = Prefs(context)
        return prefs.cameraEnabled && prefs.cameraAddress.isNotEmpty() && Permissions.hasBluetoothConnect(context)
    }

    fun show(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        createChannel(context, manager)
        val camera = Prefs(context).cameraName.ifEmpty { context.getString(R.string.camera_default_name) }
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_camera)
            .setContentTitle(context.getString(R.string.camera_notification_title, camera))
            .setContentText(context.getString(R.string.camera_notification_text))
            .setContentIntent(openIntent(context))
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)
            .build()
        runCatching { manager.notify(NOTIFICATION_ID, notification) }
            .onFailure { Log.w(Prefs.TAG, "Could not show the camera notification", it) }
    }

    fun hide(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
    }

    private fun createChannel(context: Context, manager: NotificationManager) {
        val channel = NotificationChannel(
            CHANNEL,
            context.getString(R.string.camera_channel),
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = context.getString(R.string.camera_channel_description)
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    /** Straight into XApp when it is installed, since that is what the camera is on for. */
    private fun openIntent(context: Context): PendingIntent {
        val intent = context.packageManager.getLaunchIntentForPackage(XAPP_PACKAGE)
            ?: Intent(context, CameraActivity::class.java)
        return PendingIntent.getActivity(
            context,
            REQUEST_OPEN,
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    const val CHANNEL = "fujifilm_camera"
    const val ACTION_SCAN = "pl.mwgo.macdroidsync.CAMERA_SCAN"
    private const val REQUEST_SCAN = 41
    const val NOTIFICATION_ID = 40
    private const val REQUEST_OPEN = 40
    private const val XAPP_PACKAGE = "com.fujifilm.xapp"
}

/**
 * The system's connect and disconnect broadcasts for any Bluetooth device. They
 * are among the few that still reach a receiver declared in the manifest, so the
 * notification follows the camera even when nothing of this app is running.
 */
class FujifilmCameraReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_MY_PACKAGE_REPLACED -> FujifilmCamera.watch(context)
            FujifilmCamera.ACTION_SCAN -> scanned(context, intent)
            BluetoothDevice.ACTION_ACL_CONNECTED, BluetoothDevice.ACTION_ACL_DISCONNECTED -> linked(context, intent)
        }
    }

    private fun scanned(context: Context, intent: Intent) {
        val prefs = Prefs(context)
        val error = intent.getIntExtra(BluetoothLeScanner.EXTRA_ERROR_CODE, 0)
        if (error != 0) {
            Log.w(Prefs.TAG, "Camera scan failed with $error")
            return
        }
        val type = intent.getIntExtra(BluetoothLeScanner.EXTRA_CALLBACK_TYPE, 0)
        val results = scanResults(intent)
        results.forEach { result ->
            val record = result.scanRecord
            Log.i(
                Prefs.TAG,
                "Camera scan type $type: ${result.device.address} rssi ${result.rssi} " +
                    "services ${record?.serviceUuids} data ${record?.manufacturerSpecificData}",
            )
        }
        prefs.cameraNearby = type and ScanSettings.CALLBACK_TYPE_MATCH_LOST == 0
        Log.i(Prefs.TAG, "Camera ${prefs.cameraName} ${if (prefs.cameraNearby) "on" else "gone"}")
        FujifilmCamera.refresh(context)
    }

    private fun linked(context: Context, intent: Intent) {
        val device = intent.bluetoothDevice() ?: return
        val prefs = Prefs(context)
        if (!device.address.equals(prefs.cameraAddress, ignoreCase = true)) return
        val connected = intent.action == BluetoothDevice.ACTION_ACL_CONNECTED
        Log.i(Prefs.TAG, "Camera ${prefs.cameraName} ${if (connected) "connected" else "disconnected"}")
        // Switched off while connected, the camera never advertised to say it
        // was gone, so the link going down is what says it.
        if (!connected) prefs.cameraNearby = false
        FujifilmCamera.refresh(context)
    }

    private fun scanResults(intent: Intent): List<ScanResult> =
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT, ScanResult::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableArrayListExtra(BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT)
        }.orEmpty()
}

fun Intent.bluetoothDevice(): BluetoothDevice? =
    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
        getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
    } else {
        @Suppress("DEPRECATION") getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
    }

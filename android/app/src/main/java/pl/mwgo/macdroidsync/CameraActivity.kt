package pl.mwgo.macdroidsync

import android.Manifest
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import com.google.android.material.radiobutton.MaterialRadioButton
import pl.mwgo.macdroidsync.databinding.ActivityCameraBinding

/** The Fujifilm camera to watch, whether to watch it, and the two grants it takes. */
class CameraActivity : ScreenActivity() {

    private lateinit var binding: ActivityCameraBinding
    private lateinit var prefs: Prefs

    private val bluetoothPermission =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            FujifilmCamera.watch(this)
            refresh()
        }

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { refresh() }

    /** Keeps the state line live while the screen is open. */
    private val linkReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            // The manifest receiver acts on the same broadcast; this one only redraws.
            binding.root.postDelayed({ updateState() }, 300)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityCameraBinding.inflate(layoutInflater)
        setContentView(binding.root)
        useToolbar(binding.toolbar, showUp = true)
        padFromInsets(binding.content)
        prefs = Prefs(this)

        binding.cameraSwitch.isChecked = prefs.cameraEnabled
        binding.cameraSwitch.setOnCheckedChangeListener { _, checked ->
            prefs.cameraEnabled = checked
            if (checked && !hasBluetooth()) requestBluetooth()
            FujifilmCamera.watch(this)
            updateState()
        }
        binding.bluetoothButton.setOnClickListener { requestBluetooth() }
        binding.notificationsButton.setOnClickListener { requestNotifications() }
    }

    override fun onResume() {
        super.onResume()
        ContextCompat.registerReceiver(
            this,
            linkReceiver,
            IntentFilter().apply {
                addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
                addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            },
            ContextCompat.RECEIVER_EXPORTED,
        )
        refresh()
    }

    override fun onPause() {
        super.onPause()
        unregisterReceiver(linkReceiver)
    }

    private fun refresh() {
        row(hasBluetooth(), binding.bluetoothState, binding.bluetoothButton)
        row(Permissions.hasNotifications(this), binding.notificationsState, binding.notificationsButton)
        fillCameras()
        FujifilmCamera.refresh(this)
        updateState()
    }

    private fun fillCameras() {
        val devices = FujifilmCamera.pairedDevices(this)
        // With a single camera among the paired devices there is nothing to choose.
        if (prefs.cameraAddress.isEmpty()) {
            devices.singleOrNull { FujifilmNames.looksLikeCamera(FujifilmCamera.name(it)) }?.let { choose(it) }
        }
        binding.cameraList.setOnCheckedChangeListener(null)
        binding.cameraList.removeAllViews()
        devices.forEach { device ->
            val button = MaterialRadioButton(this).apply {
                id = View.generateViewId()
                text = FujifilmCamera.name(device) ?: device.address
                tag = device
                minHeight = (48 * resources.displayMetrics.density).toInt()
            }
            binding.cameraList.addView(button)
            if (device.address.equals(prefs.cameraAddress, ignoreCase = true)) button.isChecked = true
        }
        binding.cameraList.setOnCheckedChangeListener { group, id ->
            val device = group.findViewById<View>(id)?.tag as? BluetoothDevice ?: return@setOnCheckedChangeListener
            choose(device)
        }
        binding.emptyText.visibility =
            if (devices.isEmpty() && Permissions.hasBluetoothConnect(this)) View.VISIBLE else View.GONE
    }

    private fun choose(device: BluetoothDevice) {
        if (device.address == prefs.cameraAddress) return
        FujifilmCamera.hide(this)
        prefs.cameraAddress = device.address
        prefs.cameraName = FujifilmCamera.name(device).orEmpty()
        FujifilmCamera.watch(this)
        updateState()
    }

    private fun updateState() {
        binding.stateText.setText(
            when {
                !FujifilmCamera.hasBluetooth(this) -> R.string.camera_state_no_bluetooth
                prefs.cameraAddress.isEmpty() -> R.string.camera_state_unchosen
                FujifilmCamera.isConnected(this) -> R.string.camera_state_connected
                prefs.cameraNearby -> R.string.camera_state_on
                else -> R.string.camera_state_disconnected
            }
        )
    }

    private fun requestBluetooth() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        if (hasBluetooth()) {
            openAppSettings()
        } else {
            bluetoothPermission.launch(arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN))
        }
    }

    /** Both halves of "Nearby devices": the paired camera, and its advertising. */
    private fun hasBluetooth(): Boolean =
        Permissions.hasBluetoothConnect(this) &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || Permissions.hasBluetoothScan(this))

    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || Permissions.hasNotifications(this)) {
            startActivity(
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            )
        } else {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    private fun openAppSettings() {
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
    }

    private fun row(
        granted: Boolean,
        state: android.widget.TextView,
        button: com.google.android.material.button.MaterialButton,
    ) {
        state.setText(if (granted) R.string.permission_granted else R.string.permission_missing)
        button.setText(if (granted) R.string.permission_open_settings else R.string.permission_grant)
    }
}

package pl.wojas.macdroidsync

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import pl.wojas.macdroidsync.databinding.ActivityMainBinding

/** Pairing, permissions and the on/off switch for the clipboard sync. */
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var prefs: Prefs
    private lateinit var outbox: Outbox

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { refreshPermissionButtons() }

    private val nearbyPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            refreshPermissionButtons()
            // The beacon could not start without it, so try again now.
            if (granted && prefs.beaconEnabled) SyncService.start(this, SyncService.ACTION_START)
        }

    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val connected = intent.getBooleanExtra(SyncService.EXTRA_CONNECTED, false)
            val device = intent.getStringExtra(SyncService.EXTRA_DEVICE)
            val message = intent.getStringExtra(SyncService.EXTRA_MESSAGE)
            binding.statusText.text = when {
                connected && device != null -> getString(R.string.status_connected, device)
                message != null -> message
                !prefs.syncEnabled -> getString(R.string.status_sync_off)
                else -> getString(R.string.status_connecting)
            }
            // Locking is only possible over a live session, unlike the beacon.
            binding.lockNowButton.isEnabled = connected
            refreshQueuedFiles()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        applyWindowInsets()
        prefs = Prefs(this)
        outbox = Outbox(this)

        binding.pairingCodeInput.setText(prefs.pairingCode)
        binding.hostInput.setText(prefs.manualHost)
        binding.portInput.setText(prefs.port.toString())
        binding.syncSwitch.isChecked = prefs.syncEnabled
        binding.beaconSwitch.isChecked = prefs.beaconEnabled

        binding.saveButton.setOnClickListener { save(reconnect = true) }
        binding.syncSwitch.setOnCheckedChangeListener { _, _ -> applySwitches(reconnect = true) }
        binding.beaconSwitch.setOnCheckedChangeListener { _, checked ->
            // Asking straight away: the switch does nothing without it.
            if (checked && !hasNearbyPermission()) requestNearby()
            applySwitches(reconnect = false)
        }
        binding.sendClipboardButton.setOnClickListener { sendClipboardNow() }
        binding.lockNowButton.setOnClickListener { lockTheMac() }
        binding.disconnectButton.setOnClickListener { disconnect() }
        binding.notificationsButton.setOnClickListener { requestNotifications() }
        binding.overlayButton.setOnClickListener { requestOverlay() }
        binding.nearbyButton.setOnClickListener { requestNearby() }
    }

    /**
     * Android 15 and newer draw every window edge to edge. The app bar takes care
     * of the status bar through fitsSystemWindows; this keeps the scrolling content
     * clear of the navigation bar and, more importantly, of the keyboard.
     */
    private fun applyWindowInsets() {
        ViewCompat.setOnApplyWindowInsetsListener(binding.content) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            val keyboard = insets.getInsets(WindowInsetsCompat.Type.ime())
            // Padding on the scrolling container only; the 16dp gutter lives in the
            // layout, on the child, so it is never overwritten here.
            view.updatePadding(
                left = bars.left,
                right = bars.right,
                bottom = maxOf(bars.bottom, keyboard.bottom),
            )
            insets
        }
    }

    override fun onResume() {
        super.onResume()
        ContextCompat.registerReceiver(
            this,
            statusReceiver,
            IntentFilter(SyncService.BROADCAST_STATUS),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        refreshPermissionButtons()
        refreshQueuedFiles()
        if (prefs.syncEnabled) {
            // The answer arrives as a broadcast and settles the Lock Now button.
            SyncService.start(this, SyncService.ACTION_QUERY_STATUS)
        } else {
            binding.statusText.text = getString(R.string.status_sync_off)
            binding.lockNowButton.isEnabled = false
        }
    }

    override fun onPause() {
        runCatching { unregisterReceiver(statusReceiver) }
        super.onPause()
    }

    /** Save and connect: the text fields are committed only from here. */
    private fun save(reconnect: Boolean) {
        val port = binding.portInput.text.toString().toIntOrNull() ?: Wire.DEFAULT_PORT
        prefs.pairingCode = binding.pairingCodeInput.text.toString()
        prefs.manualHost = binding.hostInput.text.toString()
        prefs.port = port.coerceIn(1024, 65535)
        binding.portInput.setText(prefs.port.toString())
        applySwitches(reconnect)
    }

    /**
     * Flipping a switch or pressing Disconnect writes **only** what those
     * controls own. The pairing code, the host and the port belong to the text
     * fields and to the Save button: committing whatever happens to be on screen
     * from an unrelated tap would quietly overwrite a working pairing with a
     * half typed one.
     */
    private fun applySwitches(reconnect: Boolean) {
        prefs.syncEnabled = binding.syncSwitch.isChecked
        prefs.beaconEnabled = binding.beaconSwitch.isChecked
        refreshPermissionButtons()

        if (!prefs.syncEnabled) {
            // The beacon rides along with the sync, so this stops both.
            SyncService.stop(this)
            binding.statusText.text = getString(R.string.status_sync_off)
            return
        }
        if (CryptoBox.normalize(prefs.pairingCode).length < MIN_CODE_LENGTH) {
            binding.statusText.text = getString(R.string.status_missing_code)
            return
        }
        binding.statusText.text = getString(R.string.status_connecting)
        SyncService.start(this, if (reconnect) SyncService.ACTION_RECONNECT else SyncService.ACTION_START)
    }

    /** Files still staged in the cache, waiting for the Mac to show up. */
    private fun refreshQueuedFiles() {
        val queued = outbox.items().size
        binding.queuedFilesText.isVisible = queued > 0
        if (queued > 0) {
            binding.queuedFilesText.text = getString(R.string.status_queued_files, queued)
        }
    }

    private fun lockTheMac() {
        SyncService.start(this, SyncService.ACTION_LOCK_MAC)
    }

    /** Ends the clipboard sync; the presence beacon keeps running on its own. */
    private fun disconnect() {
        binding.lockNowButton.isEnabled = false
        if (binding.syncSwitch.isChecked) {
            // The switch owns this state, and its listener does the saving.
            binding.syncSwitch.isChecked = false
        } else {
            SyncService.stop(this)
        }
        // Note it does not touch the pairing code: see applySwitches.
    }

    private fun sendClipboardNow() {
        startActivity(ClipboardBridgeActivity.readIntent(this))
    }

    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            openAppNotificationSettings()
            return
        }
        if (hasNotificationPermission()) {
            openAppNotificationSettings()
        } else {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    private fun openAppNotificationSettings() {
        startActivity(
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        )
    }

    private fun requestNearby() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        if (hasNearbyPermission()) {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
            )
        } else {
            nearbyPermission.launch(Manifest.permission.BLUETOOTH_ADVERTISE)
        }
    }

    private fun requestOverlay() {
        startActivity(
            Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName"),
            )
        )
    }

    private fun refreshPermissionButtons() {
        val nearby = hasNearbyPermission()
        binding.nearbyState.setText(if (nearby) R.string.permission_granted else R.string.permission_missing)
        binding.nearbyButton.setText(
            if (nearby) R.string.permission_open_settings else R.string.permission_grant
        )
        refreshBeaconHint(hasPermission = nearby)

        val notifications = hasNotificationPermission()
        binding.notificationsState.setText(if (notifications) R.string.permission_granted else R.string.permission_missing)
        binding.notificationsButton.setText(
            if (notifications) R.string.permission_open_settings else R.string.permission_grant
        )

        val overlay = Settings.canDrawOverlays(this)
        binding.overlayState.setText(if (overlay) R.string.permission_granted else R.string.permission_missing)
        binding.overlayButton.setText(
            if (overlay) R.string.permission_open_settings else R.string.permission_grant
        )
    }

    /**
     * The beacon switch on its own is not enough: it needs the Nearby devices
     * permission, and it only broadcasts while the clipboard sync is on. Both
     * are worth saying out loud, because either one leaves the Mac unable to
     * lock and the switch looking as if it works.
     */
    private fun refreshBeaconHint(hasPermission: Boolean) {
        val message = when {
            !binding.beaconSwitch.isChecked -> null
            !hasPermission -> getString(R.string.autolock_needs_permission)
            !binding.syncSwitch.isChecked -> getString(R.string.autolock_needs_sync)
            else -> null
        }
        binding.beaconHint.isVisible = message != null
        message?.let { binding.beaconHint.text = it }
    }

    /** Broadcasting the beacon is a runtime permission from Android 12 on. */
    private fun hasNearbyPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_ADVERTISE) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    companion object {
        private const val MIN_CODE_LENGTH = 8
    }
}

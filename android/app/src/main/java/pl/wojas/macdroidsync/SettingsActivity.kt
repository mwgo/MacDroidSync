package pl.wojas.macdroidsync

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import pl.wojas.macdroidsync.databinding.ActivitySettingsBinding

/**
 * Everything that is set once and then left alone: the pairing, the connection
 * and the permissions.
 *
 * The switches deliberately stay on the main screen. That split is also what
 * keeps the text fields safe: they are committed by the Save button here and by
 * nothing else, so no unrelated tap can overwrite a working pairing code with
 * whatever happens to be on screen.
 */
class SettingsActivity : ScreenActivity() {

    private lateinit var binding: ActivitySettingsBinding
    private lateinit var prefs: Prefs

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { refreshPermissionRows() }

    private val nearbyPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            refreshPermissionRows()
            // The beacon could not start without it, so try again now.
            if (granted && prefs.beaconEnabled && prefs.syncEnabled) {
                SyncService.start(this, SyncService.ACTION_START)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)
        useToolbar(binding.toolbar, showUp = true)
        padFromInsets(binding.content)
        prefs = Prefs(this)

        binding.pairingCodeInput.setText(prefs.pairingCode)
        binding.hostInput.setText(prefs.manualHost)
        binding.portInput.setText(prefs.port.toString())

        binding.saveButton.setOnClickListener { save() }
        binding.notificationsButton.setOnClickListener { requestNotifications() }
        binding.nearbyButton.setOnClickListener { requestNearby() }
        binding.overlayButton.setOnClickListener { requestOverlay() }
    }

    override fun onResume() {
        super.onResume()
        refreshPermissionRows()
    }

    /** The only place the pairing code, the host and the port are written. */
    private fun save() {
        val port = binding.portInput.text.toString().toIntOrNull() ?: Wire.DEFAULT_PORT
        prefs.pairingCode = binding.pairingCodeInput.text.toString()
        prefs.manualHost = binding.hostInput.text.toString()
        prefs.port = port.coerceIn(1024, 65535)
        binding.portInput.setText(prefs.port.toString())

        val message = when {
            CryptoBox.normalize(prefs.pairingCode).length < MIN_CODE_LENGTH -> R.string.status_missing_code
            !prefs.syncEnabled -> R.string.settings_saved_sync_off
            else -> {
                SyncService.start(this, SyncService.ACTION_RECONNECT)
                R.string.settings_saved
            }
        }
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || Permissions.hasNotifications(this)) {
            startActivity(
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            )
        } else {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    private fun requestNearby() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        if (Permissions.hasNearby(this)) {
            // Already granted, so the only thing left to offer is the place it
            // can be taken away again.
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
            )
        } else {
            nearbyPermission.launch(Manifest.permission.BLUETOOTH_ADVERTISE)
        }
    }

    private fun requestOverlay() {
        startActivity(
            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
        )
    }

    private fun refreshPermissionRows() {
        row(Permissions.hasNotifications(this), binding.notificationsState, binding.notificationsButton)
        row(Permissions.hasNearby(this), binding.nearbyState, binding.nearbyButton)
        row(Permissions.canDrawOverlays(this), binding.overlayState, binding.overlayButton)
    }

    private fun row(
        granted: Boolean,
        state: android.widget.TextView,
        button: com.google.android.material.button.MaterialButton,
    ) {
        state.setText(if (granted) R.string.permission_granted else R.string.permission_missing)
        button.setText(if (granted) R.string.permission_open_settings else R.string.permission_grant)
    }

    companion object {
        private const val MIN_CODE_LENGTH = 8

        fun intent(context: android.content.Context): Intent = Intent(context, SettingsActivity::class.java)
    }
}

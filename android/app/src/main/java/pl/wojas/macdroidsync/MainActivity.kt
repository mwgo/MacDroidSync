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
import androidx.core.view.updatePadding
import pl.wojas.macdroidsync.databinding.ActivityMainBinding

/** Pairing, permissions and the on/off switch for the clipboard sync. */
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var prefs: Prefs

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { refreshPermissionButtons() }

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
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        applyWindowInsets()
        prefs = Prefs(this)

        binding.pairingCodeInput.setText(prefs.pairingCode)
        binding.hostInput.setText(prefs.manualHost)
        binding.portInput.setText(prefs.port.toString())
        binding.syncSwitch.isChecked = prefs.syncEnabled

        binding.saveButton.setOnClickListener { save(reconnect = true) }
        binding.syncSwitch.setOnCheckedChangeListener { _, _ -> save(reconnect = true) }
        binding.sendClipboardButton.setOnClickListener { sendClipboardNow() }
        binding.notificationsButton.setOnClickListener { requestNotifications() }
        binding.overlayButton.setOnClickListener { requestOverlay() }
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
        if (prefs.syncEnabled) {
            SyncService.start(this, SyncService.ACTION_QUERY_STATUS)
        } else {
            binding.statusText.text = getString(R.string.status_sync_off)
        }
    }

    override fun onPause() {
        runCatching { unregisterReceiver(statusReceiver) }
        super.onPause()
    }

    private fun save(reconnect: Boolean) {
        val code = binding.pairingCodeInput.text.toString()
        val port = binding.portInput.text.toString().toIntOrNull() ?: Wire.DEFAULT_PORT

        prefs.pairingCode = code
        prefs.manualHost = binding.hostInput.text.toString()
        prefs.port = port.coerceIn(1024, 65535)
        prefs.syncEnabled = binding.syncSwitch.isChecked
        binding.portInput.setText(prefs.port.toString())

        if (!prefs.syncEnabled) {
            SyncService.stop(this)
            binding.statusText.text = getString(R.string.status_sync_off)
            return
        }
        if (CryptoBox.normalize(code).length < MIN_CODE_LENGTH) {
            binding.statusText.text = getString(R.string.status_missing_code)
            return
        }
        binding.statusText.text = getString(R.string.status_connecting)
        SyncService.start(this, if (reconnect) SyncService.ACTION_RECONNECT else SyncService.ACTION_START)
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

    private fun requestOverlay() {
        startActivity(
            Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName"),
            )
        )
    }

    private fun refreshPermissionButtons() {
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

    private fun hasNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    companion object {
        private const val MIN_CODE_LENGTH = 8
    }
}

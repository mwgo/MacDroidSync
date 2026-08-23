package pl.wojas.macdroidsync

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.view.Menu
import android.view.MenuItem
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.view.isVisible
import pl.wojas.macdroidsync.databinding.ActivityMainBinding

/**
 * The state of the sync and the handful of things worth doing every day.
 *
 * The switches live here because they are state, not configuration; the pairing,
 * the connection details and the permissions live behind Settings in the toolbar.
 */
class MainActivity : ScreenActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var prefs: Prefs
    private lateinit var outbox: Outbox

    private val nearbyPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            refreshBeaconHint()
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
        useToolbar(binding.toolbar)
        padFromInsets(binding.content)
        prefs = Prefs(this)
        outbox = Outbox(this)

        binding.syncSwitch.isChecked = prefs.syncEnabled
        binding.beaconSwitch.isChecked = prefs.beaconEnabled
        binding.photosSwitch.isChecked = prefs.photoSyncEnabled

        binding.syncSwitch.setOnCheckedChangeListener { _, _ -> applySwitches(reconnect = true) }
        binding.beaconSwitch.setOnCheckedChangeListener { _, checked ->
            // Asking straight away: the switch does nothing without it.
            if (checked && !Permissions.hasNearby(this)) requestNearby()
            applySwitches(reconnect = false)
        }
        binding.sendClipboardButton.setOnClickListener { sendClipboardNow() }
        binding.lockNowButton.setOnClickListener { lockTheMac() }
        binding.disconnectButton.setOnClickListener { disconnect() }
        binding.beaconHint.setOnClickListener { openSettings() }
        binding.photosSwitch.setOnCheckedChangeListener { _, _ -> applySwitches(reconnect = false) }
        binding.photosHint.setOnClickListener { openSettings() }
        binding.syncPhotosButton.setOnClickListener { syncPhotosNow() }
    }

    /**
     * Asks for a cycle right now, instead of waiting for the interval. The
     * service does the work; this only starts it and says so, because the answer
     * comes back minutes later and over the connection.
     */
    private fun syncPhotosNow() {
        if (!prefs.photoSyncEnabled || !prefs.syncEnabled) {
            refreshPhotoHint()
            return
        }
        SyncService.start(this, SyncService.ACTION_SYNC_PHOTOS)
        Toast.makeText(this, R.string.photos_sync_requested, Toast.LENGTH_SHORT).show()
    }

    /**
     * The photo switch on its own is not enough either: it needs the media
     * permissions and it rides on the clipboard connection. Saying which of the
     * two is missing is the difference between a switch that looks broken and one
     * that explains itself.
     */
    private fun refreshPhotoHint() {
        val message = when {
            !binding.photosSwitch.isChecked -> null
            Permissions.mediaRefusal(this) != null -> getString(R.string.photos_needs_permission)
            !binding.syncSwitch.isChecked -> getString(R.string.photos_needs_sync)
            else -> null
        }
        binding.photosHint.isVisible = message != null
        message?.let { binding.photosHint.text = it }
        binding.syncPhotosButton.isEnabled =
            binding.photosSwitch.isChecked && binding.syncSwitch.isChecked
    }

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        menuInflater.inflate(R.menu.main, menu)
        return true
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean = when (item.itemId) {
        R.id.action_settings -> {
            openSettings()
            true
        }
        R.id.action_about -> {
            startActivity(Intent(this, AboutActivity::class.java))
            true
        }
        else -> super.onOptionsItemSelected(item)
    }

    override fun onResume() {
        super.onResume()
        ContextCompat.registerReceiver(
            this,
            statusReceiver,
            IntentFilter(SyncService.BROADCAST_STATUS),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        // A permission may well have been granted on the settings screen while
        // this one was in the background.
        refreshBeaconHint()
        refreshPhotoHint()
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

    /**
     * Flipping a switch or pressing Disconnect writes **only** what those
     * controls own. The pairing code, the host and the port belong to the
     * settings screen and to its Save button: committing whatever happens to be
     * on screen from an unrelated tap would quietly overwrite a working pairing
     * with a half typed one.
     */
    private fun applySwitches(reconnect: Boolean) {
        prefs.syncEnabled = binding.syncSwitch.isChecked
        prefs.beaconEnabled = binding.beaconSwitch.isChecked
        prefs.photoSyncEnabled = binding.photosSwitch.isChecked
        // The first time it goes on, "from" is today unless a date was typed in
        // the settings screen: a switch nobody configured must not decide to send
        // the whole camera folder.
        if (prefs.photoSyncEnabled && prefs.photoStartDate == 0L) {
            prefs.photoStartDate = System.currentTimeMillis()
        }
        refreshBeaconHint()
        refreshPhotoHint()

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

    /**
     * The beacon switch on its own is not enough: it needs the Nearby devices
     * permission, and it only broadcasts while the clipboard sync is on. Both are
     * worth saying out loud, because either one leaves the Mac unable to lock and
     * the switch looking as if it works. The permission now lives a screen away,
     * so the hint is the way there.
     */
    private fun refreshBeaconHint() {
        val message = when {
            !binding.beaconSwitch.isChecked -> null
            !Permissions.hasNearby(this) -> getString(R.string.autolock_needs_permission)
            !binding.syncSwitch.isChecked -> getString(R.string.autolock_needs_sync)
            else -> null
        }
        binding.beaconHint.isVisible = message != null
        message?.let { binding.beaconHint.text = it }
    }

    private fun openSettings() {
        startActivity(SettingsActivity.intent(this))
    }

    private fun requestNearby() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        if (Permissions.hasNearby(this)) return
        nearbyPermission.launch(Manifest.permission.BLUETOOTH_ADVERTISE)
    }

    private fun lockTheMac() {
        SyncService.start(this, SyncService.ACTION_LOCK_MAC)
    }

    /** Ends the clipboard sync, and with it the presence beacon. */
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

    companion object {
        private const val MIN_CODE_LENGTH = 8
    }
}

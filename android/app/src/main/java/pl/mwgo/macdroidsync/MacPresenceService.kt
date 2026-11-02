package pl.mwgo.macdroidsync

import android.companion.CompanionDeviceService
import android.companion.DevicePresenceEvent
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi

/**
 * Told by the system when the Mac comes into range or goes, see
 * MacCompanion.observe. Unlike the app's own scan this keeps working while the
 * app's process is frozen: the system scans and binds here.
 */
@RequiresApi(Build.VERSION_CODES.S)
class MacPresenceService : CompanionDeviceService() {

    // From Android 16 the system calls these as well as onDevicePresenceEvent.
    @Deprecated("Before Android 16")
    override fun onDeviceAppeared(address: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.BAKLAVA) changed(address, nearby = true)
    }

    @Deprecated("Before Android 16")
    override fun onDeviceDisappeared(address: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.BAKLAVA) changed(address, nearby = false)
    }

    @RequiresApi(Build.VERSION_CODES.BAKLAVA)
    override fun onDevicePresenceEvent(event: DevicePresenceEvent) {
        val nearby = when (event.event) {
            DevicePresenceEvent.EVENT_BLE_APPEARED, DevicePresenceEvent.EVENT_BT_CONNECTED -> true
            DevicePresenceEvent.EVENT_BLE_DISAPPEARED, DevicePresenceEvent.EVENT_BT_DISCONNECTED -> false
            else -> return
        }
        val address = MacCompanion.addressOf(this, event.associationId) ?: return
        changed(address, nearby)
    }

    private fun changed(address: String, nearby: Boolean) {
        if (!address.equals(MacScanner.address(this), ignoreCase = true)) return
        Log.i(Prefs.TAG, "Mac ${if (nearby) "in range" else "out of range"}, told by the system")
        if (nearby) MacNearbyReceiver.appeared(this, inRange = true) else MacScanner.markLost(this)
    }
}

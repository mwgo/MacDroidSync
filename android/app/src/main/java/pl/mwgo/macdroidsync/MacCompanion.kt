package pl.mwgo.macdroidsync

import android.companion.CompanionDeviceManager
import android.companion.ObservingDevicePresenceRequest
import android.content.Context
import android.os.Build
import android.util.Log

/**
 * The Mac as this app's companion device, linked by its Bluetooth address once
 * the phone is paired with it. Two things come of that: the service may start
 * from the background, and the system itself tells [MacPresenceService] when
 * the Mac comes into range or goes. The latter keeps working while Samsung
 * keeps the app frozen, which stops the app's own scan (see MacScanner).
 */
object MacCompanion {

    fun isLinked(context: Context): Boolean {
        val address = MacScanner.address(context) ?: return false
        return companions(context).any { it.second.equals(address, ignoreCase = true) }
    }

    /**
     * Has the system watch the Mac, and drops every other association: one
     * left over from an older version would grant the background start for a
     * device that is not the Mac at all.
     */
    fun observe(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val manager = context.getSystemService(CompanionDeviceManager::class.java) ?: return
        val address = MacScanner.address(context) ?: return
        val all = companions(context)
        if (all.none { it.second.equals(address, ignoreCase = true) }) return
        all.forEach { (id, mac) ->
            val result = runCatching {
                if (mac.equals(address, ignoreCase = true)) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA && id != null) {
                        manager.startObservingDevicePresence(
                            ObservingDevicePresenceRequest.Builder().setAssociationId(id).build()
                        )
                    } else {
                        @Suppress("DEPRECATION") manager.startObservingDevicePresence(mac)
                    }
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && id != null) {
                    manager.disassociate(id)
                } else {
                    @Suppress("DEPRECATION") manager.disassociate(mac)
                }
            }
            val what = if (mac.equals(address, ignoreCase = true)) "System watching for the Mac" else "Dropped the association with"
            Log.i(Prefs.TAG, "$what $mac: ${result.exceptionOrNull() ?: "ok"}")
        }
    }

    /** The address of the associated device the system reports by its id. */
    fun addressOf(context: Context, associationId: Int): String? =
        companions(context).firstOrNull { it.first == associationId }?.second

    /** This app's associated devices, by association id (from Android 13) and address. */
    private fun companions(context: Context): List<Pair<Int?, String>> {
        val manager = context.getSystemService(CompanionDeviceManager::class.java) ?: return emptyList()
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                manager.myAssociations.mapNotNull { info -> info.deviceMacAddress?.let { info.id to it.toString() } }
            } else {
                @Suppress("DEPRECATION") manager.associations.map { null to it }
            }
        }.getOrDefault(emptyList())
    }
}

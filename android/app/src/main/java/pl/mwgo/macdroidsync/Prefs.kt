package pl.mwgo.macdroidsync

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.util.UUID

/**
 * Settings storage. The pairing code is the shared secret, so preferences are
 * encrypted; if the keystore is unavailable the app falls back to private
 * preferences instead of refusing to start.
 */
class Prefs(context: Context) {

    private val prefs: SharedPreferences = createStore(context)

    var pairingCode: String
        get() = prefs.getString(KEY_PAIRING_CODE, "").orEmpty()
        set(value) = prefs.edit().putString(KEY_PAIRING_CODE, value.trim()).apply()

    /** Empty means "discover the Mac over Bonjour". */
    var manualHost: String
        get() = prefs.getString(KEY_HOST, "").orEmpty()
        set(value) = prefs.edit().putString(KEY_HOST, value.trim()).apply()

    var port: Int
        get() = prefs.getInt(KEY_PORT, Wire.DEFAULT_PORT)
        set(value) = prefs.edit().putInt(KEY_PORT, value).apply()

    var syncEnabled: Boolean
        get() = prefs.getBoolean(KEY_SYNC_ENABLED, false)
        set(value) = prefs.edit().putBoolean(KEY_SYNC_ENABLED, value).apply()

    /**
     * Whether this phone broadcasts the presence beacon the Mac uses to lock
     * itself when the user walks away. Only takes effect while [syncEnabled] is
     * on: the beacon rides along with the sync rather than keeping the service
     * alive on its own.
     */
    var beaconEnabled: Boolean
        get() = prefs.getBoolean(KEY_BEACON_ENABLED, false)
        set(value) = prefs.edit().putBoolean(KEY_BEACON_ENABLED, value).apply()

    /** Whether the notification follows the Fujifilm camera's Bluetooth link. */
    var cameraEnabled: Boolean
        get() = prefs.getBoolean(KEY_CAMERA_ENABLED, false)
        set(value) = prefs.edit().putBoolean(KEY_CAMERA_ENABLED, value).apply()

    /** The paired camera watched, by its Bluetooth address; empty until one is chosen. */
    var cameraAddress: String
        get() = prefs.getString(KEY_CAMERA_ADDRESS, "").orEmpty()
        set(value) = prefs.edit().putString(KEY_CAMERA_ADDRESS, value).apply()

    var cameraName: String
        get() = prefs.getString(KEY_CAMERA_NAME, "").orEmpty()
        set(value) = prefs.edit().putString(KEY_CAMERA_NAME, value).apply()

    /** Whether the camera is sent the phone's location and the time while it is on. */
    var cameraGeoEnabled: Boolean
        get() = prefs.getBoolean(KEY_CAMERA_GEO, true)
        set(value) = prefs.edit().putBoolean(KEY_CAMERA_GEO, value).apply()

    /** Seconds between two rounds of location and time. */
    var cameraGeoInterval: Int
        get() = prefs.getInt(KEY_CAMERA_GEO_INTERVAL, FujifilmGeo.DEFAULT_INTERVAL)
        set(value) = prefs.edit().putInt(KEY_CAMERA_GEO_INTERVAL, value).apply()

    /** The camera's Wi-Fi as "ssid\npassphrase\nbssid", to rejoin it when Bluetooth is gone. */
    var cameraWifi: String
        get() = prefs.getString(KEY_CAMERA_WIFI, "").orEmpty()
        set(value) = prefs.edit().putString(KEY_CAMERA_WIFI, value).apply()

    /** When the camera was last seen or heard over Bluetooth, in wall clock milliseconds. */
    var cameraLastSeen: Long
        get() = prefs.getLong(KEY_CAMERA_LAST_SEEN, 0L)
        set(value) = prefs.edit().putLong(KEY_CAMERA_LAST_SEEN, value).apply()

    /** Whether the background scan last saw the camera advertising, that is switched on. */
    var cameraNearby: Boolean
        get() = prefs.getBoolean(KEY_CAMERA_NEARBY, false)
        set(value) = prefs.edit().putBoolean(KEY_CAMERA_NEARBY, value).apply()

    // Photo sync has no settings here any more: the Mac holds all of them and
    // sends them at the start of every session. What is left on this phone is
    // the media permission, which is the one thing a Mac cannot grant.

    /** Stable id of this phone, generated on first use. */
    val deviceId: String
        get() = prefs.getString(KEY_DEVICE_ID, null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString(KEY_DEVICE_ID, it).apply()
        }

    private fun createStore(context: Context): SharedPreferences = try {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            "macdroidsync-secure",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    } catch (error: Exception) {
        Log.w(TAG, "Encrypted preferences unavailable, using private preferences", error)
        context.getSharedPreferences("macdroidsync", Context.MODE_PRIVATE)
    }

    companion object {
        const val TAG = "MacDroidSync"
        private const val KEY_PAIRING_CODE = "pairingCode"
        private const val KEY_HOST = "manualHost"
        private const val KEY_PORT = "port"
        private const val KEY_SYNC_ENABLED = "syncEnabled"
        private const val KEY_BEACON_ENABLED = "beaconEnabled"
        private const val KEY_DEVICE_ID = "deviceId"
        private const val KEY_CAMERA_ENABLED = "cameraEnabled"
        private const val KEY_CAMERA_ADDRESS = "cameraAddress"
        private const val KEY_CAMERA_NAME = "cameraName"
        private const val KEY_CAMERA_NEARBY = "cameraNearby"
        private const val KEY_CAMERA_WIFI = "cameraWifi"
        private const val KEY_CAMERA_LAST_SEEN = "cameraLastSeen"
        private const val KEY_CAMERA_GEO = "cameraGeo"
        private const val KEY_CAMERA_GEO_INTERVAL = "cameraGeoInterval"
    }
}

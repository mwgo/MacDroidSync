package pl.wojas.macdroidsync

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

    /**
     * Whether the camera folder is described to the Mac at all. Off until it is
     * turned on: this is the switch the feature is required to have.
     */
    var photoSyncEnabled: Boolean
        get() = prefs.getBoolean(KEY_PHOTO_ENABLED, false)
        set(value) = prefs.edit().putBoolean(KEY_PHOTO_ENABLED, value).apply()

    /**
     * Nothing taken before this is ever synced. Milliseconds; zero means "no date
     * of its own", in which case the day count below is the only bound.
     */
    var photoStartDate: Long
        get() = prefs.getLong(KEY_PHOTO_START, 0)
        set(value) = prefs.edit().putLong(KEY_PHOTO_START, value).apply()

    /**
     * How far back to look, in days. This is the fuse: with a start date set to
     * 2005, it is still this number that decides, because the effective bound is
     * the later of the two.
     */
    var photoLastDays: Int
        get() = prefs.getInt(KEY_PHOTO_DAYS, 30)
        set(value) = prefs.edit().putInt(KEY_PHOTO_DAYS, value.coerceIn(1, 3650)).apply()

    /** How often a cycle runs while the sync is connected. */
    var photoIntervalMinutes: Int
        get() = prefs.getInt(KEY_PHOTO_INTERVAL, 30)
        set(value) = prefs.edit().putInt(KEY_PHOTO_INTERVAL, value.coerceIn(5, 1440)).apply()

    /**
     * The largest single item worth starting. There is no resume in the protocol,
     * so anything bigger than this restarts from zero on every dropped
     * connection; past a couple of gigabytes that simply never finishes.
     */
    var photoMaxItemBytes: Long
        get() = prefs.getLong(KEY_PHOTO_MAX_ITEM, Wire.MAX_PHOTO_BYTES)
        set(value) = prefs.edit().putLong(KEY_PHOTO_MAX_ITEM, value).apply()

    /** When the last cycle ran, so the interval survives a restart. */
    var lastPhotoCycleAt: Long
        get() = prefs.getLong(KEY_PHOTO_LAST_CYCLE, 0)
        set(value) = prefs.edit().putLong(KEY_PHOTO_LAST_CYCLE, value).apply()

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
        private const val KEY_PHOTO_ENABLED = "photoSyncEnabled"
        private const val KEY_PHOTO_START = "photoStartDate"
        private const val KEY_PHOTO_DAYS = "photoLastDays"
        private const val KEY_PHOTO_INTERVAL = "photoIntervalMinutes"
        private const val KEY_PHOTO_MAX_ITEM = "photoMaxItemBytes"
        private const val KEY_PHOTO_LAST_CYCLE = "lastPhotoCycleAt"
    }
}

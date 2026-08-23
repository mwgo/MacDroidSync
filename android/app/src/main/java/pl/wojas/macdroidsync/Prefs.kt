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
        private const val KEY_DEVICE_ID = "deviceId"
    }
}

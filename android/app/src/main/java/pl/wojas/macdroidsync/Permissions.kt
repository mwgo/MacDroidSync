package pl.wojas.macdroidsync

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat

/**
 * The three permissions this app cares about, asked in one place.
 *
 * Each of them is checked from several unrelated corners - the main screen, the
 * settings screen, the beacon and the clipboard bridge - and each has a version
 * cut-off that is easy to get subtly wrong. Keeping the checks together is what
 * stops the screens from disagreeing about whether something is granted.
 */
object Permissions {

    /** Broadcasting the presence beacon; a runtime permission from Android 12 on. */
    fun hasNearby(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_ADVERTISE) ==
            PackageManager.PERMISSION_GRANTED

    /** Runtime permission from Android 13 on; before that notifications just work. */
    fun hasNotifications(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * "Display over other apps". Android only lets an app read or write the
     * clipboard while it has a focused window, and this is what allows the
     * transparent window to be opened from the background.
     */
    fun canDrawOverlays(context: Context): Boolean = Settings.canDrawOverlays(context)
}

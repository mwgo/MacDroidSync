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

    /**
     * Reading the camera folder. Three eras of Android, three answers: separate
     * image and video grants from 13, one storage grant from 10 to 12, and the
     * legacy storage permission on 9.
     */
    fun hasMediaRead(context: Context): Boolean = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->
            granted(context, Manifest.permission.READ_MEDIA_IMAGES) &&
                granted(context, Manifest.permission.READ_MEDIA_VIDEO)
        else -> @Suppress("DEPRECATION") granted(context, Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    /**
     * Whether the user granted access to a hand-picked set of photos rather than
     * to all of them, which Android 14 offers.
     *
     * This matters far beyond the wording of a settings row: a partial grant makes
     * MediaStore describe a camera folder holding a handful of files, and that is
     * indistinguishable from a camera folder whose photos were all deleted. Any
     * sync built on it would tell the Mac to remove almost everything.
     */
    fun hasPartialMediaRead(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
            granted(context, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) &&
            !(granted(context, Manifest.permission.READ_MEDIA_IMAGES) &&
                granted(context, Manifest.permission.READ_MEDIA_VIDEO))

    /**
     * Un-redacted EXIF, which is where the location of a photo lives. Without it
     * MediaStore hands over bytes with the GPS tags removed, and a photo that
     * arrives without its location looks perfectly fine while being wrong.
     */
    fun hasMediaLocation(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            granted(context, Manifest.permission.ACCESS_MEDIA_LOCATION)

    /**
     * Why the phone cannot describe its camera folder right now, or null when it
     * can. This is the sentence the Mac is told, and while it is not null nothing
     * is synced and - crucially - nothing is deleted there.
     */
    fun mediaRefusal(context: Context): String? = when {
        !hasMediaRead(context) ->
            if (hasPartialMediaRead(context)) {
                "MacDroidSync may only see selected photos, which cannot be told apart from a " +
                    "camera folder that was emptied"
            } else {
                "MacDroidSync has no permission to read photos and videos"
            }
        !hasMediaLocation(context) ->
            "MacDroidSync may not read photo locations, and would deliver photos with the " +
                "location stripped out"
        else -> null
    }

    private fun granted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
}

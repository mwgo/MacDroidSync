package pl.mwgo.macdroidsync

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
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

    /**
     * Seeing paired devices and their connections, for the Fujifilm camera; a
     * runtime permission from Android 12 on, implied by BLUETOOTH before it.
     */
    fun hasBluetoothConnect(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            granted(context, Manifest.permission.BLUETOOTH_CONNECT)

    /**
     * Noticing the camera switched on, by its advertising, without any app
     * connected to it. Only from Android 12: before it a scan needs the location.
     */
    fun hasBluetoothScan(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            granted(context, Manifest.permission.BLUETOOTH_SCAN)

    /**
     * The location sent to the camera. It is read while no screen of this app
     * is open, which takes the "all the time" grant from Android 10 on.
     */
    fun hasCameraLocation(context: Context): Boolean =
        granted(context, Manifest.permission.ACCESS_FINE_LOCATION) &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
                granted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION))

    fun hasForegroundLocation(context: Context): Boolean =
        granted(context, Manifest.permission.ACCESS_FINE_LOCATION)

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

    /** Reading the messages the Mac shows, see PROTOCOL.md section 9. */
    fun hasSmsRead(context: Context): Boolean = granted(context, Manifest.permission.READ_SMS)

    fun hasSmsSend(context: Context): Boolean = granted(context, Manifest.permission.SEND_SMS)

    /** Names instead of bare numbers. Optional: without it the Mac shows numbers. */
    fun hasContacts(context: Context): Boolean = granted(context, Manifest.permission.READ_CONTACTS)

    /** The sentence the Mac shows when it cannot have the messages, or null. */
    fun smsRefusal(context: Context): String? =
        if (hasSmsRead(context)) null else "MacDroidSync has no permission to read messages on the phone"

    val smsPermissions = arrayOf(
        Manifest.permission.READ_SMS,
        Manifest.permission.SEND_SMS,
        Manifest.permission.READ_CONTACTS,
    )

    /**
     * Reading and writing the synced folders anywhere in the shared storage:
     * "all files access" from Android 11 on, the storage permission before.
     */
    fun hasAllFiles(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            @Suppress("DEPRECATION") granted(context, Manifest.permission.WRITE_EXTERNAL_STORAGE)
        }

    private fun granted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
}

package pl.wojas.macdroidsync

import android.content.Context
import android.content.res.Configuration
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AppCompatDelegate

/**
 * Light or dark for the notes screens only, as chosen on the notes list; until
 * then they follow the system. The sync screens are left as they are.
 */
object NotesTheme {
    private const val PREFS = "notes"
    private const val NIGHT = "night"

    /** Called before the activity's own onCreate, so it is created in the chosen mode. */
    fun apply(activity: AppCompatActivity) {
        activity.delegate.localNightMode = when (prefs(activity).getString(NIGHT, null)) {
            "dark" -> AppCompatDelegate.MODE_NIGHT_YES
            "light" -> AppCompatDelegate.MODE_NIGHT_NO
            else -> AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM
        }
    }

    fun isDark(activity: AppCompatActivity) =
        activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

    /** Switches to the other mode, which recreates [activity] in it. */
    fun toggle(activity: AppCompatActivity) {
        prefs(activity).edit().putString(NIGHT, if (isDark(activity)) "light" else "dark").apply()
        apply(activity)
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

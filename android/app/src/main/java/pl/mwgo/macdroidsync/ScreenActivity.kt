package pl.mwgo.macdroidsync

import android.content.res.Configuration
import android.view.View
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.Toolbar
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding

/** The window chrome the three screens share. */
abstract class ScreenActivity : AppCompatActivity() {

    /**
     * Android 15 and newer draw every window edge to edge. The app bar takes care
     * of the status bar through fitsSystemWindows; this keeps the scrolling content
     * clear of the navigation bar and, more importantly, of the keyboard.
     */
    protected fun padFromInsets(content: View) {
        ViewCompat.setOnApplyWindowInsetsListener(content) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            val keyboard = insets.getInsets(WindowInsetsCompat.Type.ime())
            // Padding on the scrolling container only; the 16dp gutter lives in the
            // layout, on the child, so it is never overwritten here.
            view.updatePadding(
                left = bars.left,
                right = bars.right,
                bottom = maxOf(bars.bottom, keyboard.bottom),
            )
            insets
        }
    }

    /**
     * For a screen without an app bar: [page] keeps clear of the status bar
     * itself, and the status bar gets dark icons on a light background.
     */
    protected fun keepClearOfStatusBar(page: View) {
        val night = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        WindowCompat.getInsetsController(window, window.decorView).isAppearanceLightStatusBars = !night
        ViewCompat.setOnApplyWindowInsetsListener(page) { view, insets ->
            view.updatePadding(top = insets.getInsets(WindowInsetsCompat.Type.statusBars()).top)
            insets
        }
    }

    /**
     * The toolbar becomes the action bar, which is what gives the secondary
     * screens their back arrow: AppCompat routes it through the parent activity
     * declared in the manifest.
     */
    protected fun useToolbar(toolbar: Toolbar, showUp: Boolean = false) {
        setSupportActionBar(toolbar)
        supportActionBar?.setDisplayHomeAsUpEnabled(showUp)
    }
}

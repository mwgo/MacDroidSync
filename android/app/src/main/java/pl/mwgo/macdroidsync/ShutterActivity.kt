package pl.mwgo.macdroidsync

import android.annotation.SuppressLint
import android.os.Bundle
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import pl.mwgo.macdroidsync.databinding.ActivityShutterBinding

/**
 * A remote shutter button for the Fujifilm camera, opened from its notification.
 * Held down, it holds the camera's shutter button down too.
 */
class ShutterActivity : ScreenActivity() {

    private lateinit var binding: ActivityShutterBinding
    private var pressed = false

    @SuppressLint("ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityShutterBinding.inflate(layoutInflater)
        setContentView(binding.root)
        useToolbar(binding.toolbar, showUp = false)
        val prefs = Prefs(this)
        supportActionBar?.title = prefs.cameraName.ifEmpty { getString(R.string.camera_default_name) }

        // The same switch as on the camera settings screen: off, nothing runs at all.
        binding.linkCheck.isChecked = prefs.cameraEnabled
        binding.linkCheck.setOnCheckedChangeListener { _, checked ->
            prefs.cameraEnabled = checked
            FujifilmCamera.watch(this)
            update()
        }

        binding.shutterButton.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> press(view, true)
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> press(view, false)
            }
            false
        }
        // Talkback and switch access use a click: one photo.
        binding.shutterButton.setOnClickListener {
            if (!pressed && it.isAccessibilityFocused) {
                CameraLinkService.instance?.run { shutter(true); shutter(false) }
            }
        }
        binding.xappButton.setOnClickListener { FujifilmCamera.openXApp(this) }
        binding.xappButton.visibility =
            if (packageManager.getLaunchIntentForPackage("com.fujifilm.xapp") != null) View.VISIBLE else View.GONE
    }

    override fun onResume() {
        super.onResume()
        CameraLinkService.onChange = { update() }
        binding.linkCheck.isChecked = Prefs(this).cameraEnabled
        if (!CameraLinkService.running) FujifilmCamera.refresh(this)
        update()
    }

    override fun onPause() {
        super.onPause()
        if (pressed) press(binding.shutterButton, false)
        CameraLinkService.onChange = null
    }

    private fun press(view: View, down: Boolean) {
        val link = CameraLinkService.instance?.takeIf { it.ready } ?: return
        if (down == pressed) return
        pressed = down
        view.performHapticFeedback(if (down) HapticFeedbackConstants.VIRTUAL_KEY else HapticFeedbackConstants.VIRTUAL_KEY_RELEASE)
        link.shutter(down)
    }

    private fun update() {
        val ready = CameraLinkService.instance?.ready == true
        binding.shutterButton.isEnabled = ready
        binding.stateText.setText(
            when {
                !Prefs(this).cameraEnabled -> R.string.shutter_link_off
                ready -> R.string.shutter_ready
                FujifilmCamera.isOn(this) -> R.string.camera_sync_connecting
                else -> R.string.camera_state_disconnected
            }
        )
    }
}

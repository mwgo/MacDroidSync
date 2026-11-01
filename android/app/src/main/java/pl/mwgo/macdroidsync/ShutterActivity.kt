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
        // Clear of the navigation bar, which in landscape would cut into the shutter.
        padFromInsets(binding.root)
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
        binding.downloadButton.setOnClickListener {
            if (CameraPhotos.downloading) CameraPhotos.stopImport() else importNew()
        }
        binding.browseButton.setOnClickListener {
            startActivity(android.content.Intent(this, PhotoViewerActivity::class.java))
        }
        // Held, it opens straight onto the tiles.
        binding.browseButton.setOnLongClickListener {
            it.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
            startActivity(
                android.content.Intent(this, PhotoViewerActivity::class.java).putExtra(PhotoViewerActivity.EXTRA_GRID, true)
            )
            true
        }
        binding.xappButton.setOnClickListener { FujifilmCamera.openXApp(this) }
        if (savedInstanceState == null && intent.getBooleanExtra(EXTRA_CONNECT, false)) {
            CameraPhotos.connect(this) { update() }
        }
        binding.xappButton.visibility =
            if (packageManager.getLaunchIntentForPackage("com.fujifilm.xapp") != null) View.VISIBLE else View.GONE
    }

    override fun onResume() {
        super.onResume()
        CameraLinkService.onChange = { update() }
        CameraPhotos.onChange = { update() }
        binding.linkCheck.isChecked = Prefs(this).cameraEnabled
        if (!CameraLinkService.running) FujifilmCamera.refresh(this)
        update()
    }

    override fun onPause() {
        super.onPause()
        if (pressed) press(binding.shutterButton, false)
        CameraLinkService.onChange = null
        CameraPhotos.onChange = null
    }

    private fun importNew() {
        CameraPhotos.importNew(this) { count, stopped ->
            val folder = Prefs(this).cameraName.ifEmpty { getString(R.string.camera_default_name) }
            val message = when {
                stopped -> getString(R.string.photos_stopped, count)
                count == 0 -> getString(R.string.photos_nothing_new)
                else -> getString(R.string.photos_downloaded, count, folder)
            }
            android.widget.Toast.makeText(this, message, android.widget.Toast.LENGTH_LONG).show()
            update()
        }
        update()
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
        val importing = CameraPhotos.importing
        val photos = CameraPhotos.state
        // Grey with the camera off: only Bluetooth, or a session already open, can reach it.
        val reachable = ready || photos is CameraPhotos.State.Ready
        val busy = photos is CameraPhotos.State.Busy && importing == null
        val downloading = CameraPhotos.downloading
        binding.downloadButton.isEnabled = downloading || (reachable && !busy)
        // From the tap on, the green button is a red stop inside a ring of progress.
        val color = when {
            downloading -> R.color.camera_stop
            !binding.downloadButton.isEnabled -> R.color.camera_off
            else -> R.color.camera_download
        }
        binding.downloadButton.backgroundTintList = androidx.core.content.ContextCompat.getColorStateList(this, color)
        binding.downloadButton.setIconResource(if (downloading) R.drawable.ic_stop else R.drawable.ic_download)
        binding.downloadButton.contentDescription =
            getString(if (downloading) R.string.photos_download_stop else R.string.photos_download_new)
        binding.downloadProgress.visibility = if (importing != null || busy) View.VISIBLE else View.INVISIBLE
        if (importing != null) {
            binding.downloadProgress.isIndeterminate = false
            binding.downloadProgress.setProgressCompat(importing.first * 100 / importing.second.coerceAtLeast(1), true)
        } else if (busy && !binding.downloadProgress.isIndeterminate) {
            binding.downloadProgress.visibility = View.INVISIBLE
            binding.downloadProgress.isIndeterminate = true
            binding.downloadProgress.visibility = View.VISIBLE
        }
        // A tint of its own hides the disabled look, so it is faded here.
        binding.shutterButton.alpha = if (binding.shutterButton.isEnabled) 1f else 0.38f
        binding.downloadText.text = when {
            importing != null -> getString(R.string.photos_progress, importing.first + 1, importing.second)
            busy -> getString((photos as CameraPhotos.State.Busy).step)
            else -> getString(R.string.photos_download_short)
        }
        // The last failure stays readable above the button until the next try.
        binding.stateText.text = when {
            !Prefs(this).cameraEnabled -> getString(R.string.shutter_link_off)
            photos is CameraPhotos.State.Failed -> photos.reason
            ready -> getString(R.string.shutter_ready)
            FujifilmCamera.isOn(this) -> getString(R.string.camera_sync_connecting)
            else -> getString(R.string.camera_state_disconnected)
        }
    }

    companion object {
        /** Opened to join the camera's Wi-Fi straight away. */
        const val EXTRA_CONNECT = "connect"
    }
}

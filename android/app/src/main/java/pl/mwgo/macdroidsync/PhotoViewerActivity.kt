package pl.mwgo.macdroidsync

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.format.DateUtils
import android.util.LruCache
import android.util.Size
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.TextView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.PagerSnapHelper
import androidx.recyclerview.widget.RecyclerView
import androidx.transition.ChangeBounds
import androidx.transition.TransitionManager
import com.google.android.material.snackbar.Snackbar
import pl.mwgo.macdroidsync.databinding.ActivityPhotoViewerBinding
import java.util.Calendar
import java.util.concurrent.Executors

/**
 * The camera's pictures, newest first, one per screen: swipe for older ones,
 * pinch or double tap to zoom, flick up to throw one away. Pinched in past its
 * whole size, a picture gives way to tiles under their dates, two, four or six
 * to a row.
 * A picture not imported yet is imported as soon as it is shown, its small
 * preview standing in meanwhile.
 */
class PhotoViewerActivity : ScreenActivity() {

    private lateinit var binding: ActivityPhotoViewerBinding
    private val pages = Pages()
    private val tiles = Tiles()
    private val decoder = Executors.newFixedThreadPool(2)
    private val thumbs = LruCache<String, Bitmap>(THUMB_CACHE)
    private val pageLayout by lazy { LinearLayoutManager(this, LinearLayoutManager.HORIZONTAL, false) }
    private val gridLayout by lazy { GridLayoutManager(this, TILE_SIZES.first()) }
    private var photos: List<CameraPhotos.Photo> = emptyList()
    /** Thrown away but still undoable; out of every list meanwhile. */
    private var pendingTrash: CameraPhotos.Photo? = null
    private var undo: Snackbar? = null
    private var captionShown = true
    /** Keys of the tiles picked by a long press and taps after it; empty when not selecting. */
    private val selected = linkedSetOf<String>()
    private var selecting = false
    private var downloadingSelection: Pair<Int, Int>? = null
    /** A long press that keeps moving selects every tile it passes, from where it began. */
    private var dragAnchor = RecyclerView.NO_POSITION
    private var dragLast = RecyclerView.NO_POSITION
    private var dragSelects = true
    private var dragBase: Set<String> = emptySet()
    private val leaveSelection = object : androidx.activity.OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = endSelection()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityPhotoViewerBinding.inflate(layoutInflater)
        setContentView(binding.root)
        hideStatusBar()

        binding.pager.layoutManager = pageLayout
        binding.pager.adapter = pages
        PagerSnapHelper().attachToRecyclerView(binding.pager)
        binding.pager.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrollStateChanged(view: RecyclerView, state: Int) {
                if (state == RecyclerView.SCROLL_STATE_IDLE) updateCaption()
            }
        })

        gridLayout.spanSizeLookup = object : GridLayoutManager.SpanSizeLookup() {
            override fun getSpanSize(position: Int) = if (tiles.isDay(position)) gridLayout.spanCount else 1
        }
        binding.grid.layoutManager = gridLayout
        binding.grid.adapter = tiles
        binding.grid.addOnItemTouchListener(object : RecyclerView.SimpleOnItemTouchListener() {
            override fun onInterceptTouchEvent(view: RecyclerView, event: MotionEvent): Boolean {
                if (dragAnchor == RecyclerView.NO_POSITION) return false
                if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
                    dragAnchor = RecyclerView.NO_POSITION
                    return false
                }
                return event.actionMasked == MotionEvent.ACTION_MOVE
            }

            override fun onTouchEvent(view: RecyclerView, event: MotionEvent) {
                when (event.actionMasked) {
                    MotionEvent.ACTION_MOVE -> dragTo(event.x, event.y)
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> dragAnchor = RecyclerView.NO_POSITION
                }
            }
        })
        onBackPressedDispatcher.addCallback(this, leaveSelection)
        binding.selectionClose.setOnClickListener { endSelection() }
        binding.selectionDownload.setOnClickListener { downloadSelection() }
        binding.selectionDelete.setOnClickListener { confirmDeleteSelection() }
        if (savedInstanceState == null && intent.getBooleanExtra(EXTRA_GRID, false)) {
            binding.grid.visibility = View.VISIBLE
            binding.pager.visibility = View.INVISIBLE
            binding.pager.alpha = 0f
        }
        val pinch = ScaleGestureDetector(this, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            private var total = 1f
            override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                total = 1f
                return true
            }

            override fun onScale(detector: ScaleGestureDetector): Boolean {
                total *= detector.scaleFactor
                // Pinching in makes the tiles smaller, one step at a time; spreading, larger.
                val step = TILE_SIZES.indexOf(gridLayout.spanCount)
                when {
                    total < PINCH_SMALLER && step < TILE_SIZES.lastIndex -> setSpan(TILE_SIZES[step + 1])
                    total > PINCH_LARGER && step > 0 -> setSpan(TILE_SIZES[step - 1])
                    else -> return true
                }
                total = 1f
                return true
            }
        })
        binding.grid.addOnItemTouchListener(object : RecyclerView.SimpleOnItemTouchListener() {
            override fun onInterceptTouchEvent(view: RecyclerView, event: MotionEvent): Boolean {
                pinch.onTouchEvent(event)
                return event.pointerCount > 1
            }

            override fun onTouchEvent(view: RecyclerView, event: MotionEvent) {
                pinch.onTouchEvent(event)
            }
        })

    }

    override fun onResume() {
        super.onResume()
        CameraPhotos.onChange = { refresh() }
        CameraPhotos.held = true
        refresh()
        if (CameraLinkService.instance?.ready == true) CameraPhotos.connect(this) { refresh() }
    }

    override fun onPause() {
        super.onPause()
        CameraPhotos.onChange = null
        CameraPhotos.held = false
        // Leaving is not undoing.
        undo?.dismiss()
        commitTrash()
    }

    override fun onDestroy() {
        super.onDestroy()
        decoder.shutdownNow()
    }

    /** The picture is the whole screen; the status bar comes back with a swipe from the top. */
    private fun hideStatusBar() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.statusBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun refresh() {
        val current = currentPhoto()?.key
        photos = CameraPhotos.photos(this).filter { it.key != pendingTrash?.key }
        pages.notifyDataSetChanged()
        tiles.build(photos)
        current?.let { key -> photos.indexOfFirst { it.key == key }.takeIf { it >= 0 }?.let(pageLayout::scrollToPosition) }
        val note = when (val state = CameraPhotos.state) {
            is CameraPhotos.State.Busy -> getString(state.step)
            is CameraPhotos.State.Failed -> state.reason
            else -> null
        }
        binding.emptyText.visibility = if (photos.isEmpty()) View.VISIBLE else View.GONE
        binding.emptyText.text = note ?: getString(R.string.photos_none)
        binding.stateText.visibility = if (note != null && photos.isNotEmpty()) View.VISIBLE else View.GONE
        binding.stateText.text = note
        if (selecting) {
            selected.retainAll(photos.map { it.key }.toSet())
            updateSelectionBar()
        }
        // Which picture shows is known only once the list is laid out.
        binding.pager.post { updateCaption() }
    }

    private fun currentPhoto(): CameraPhotos.Photo? {
        val position = pageLayout.findFirstCompletelyVisibleItemPosition().takeIf { it >= 0 }
            ?: pageLayout.findFirstVisibleItemPosition()
        return photos.getOrNull(position)
    }

    private fun updateCaption() {
        val photo = currentPhoto()
        val date = photo?.takeIf { it.taken > 0 }?.let {
            DateUtils.formatDateTime(this, it.taken, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_TIME or DateUtils.FORMAT_ABBREV_MONTH)
        }
        binding.caption.text = listOfNotNull(photo?.filename?.substringBeforeLast('.'), date).joinToString(" · ")
        val single = binding.grid.visibility != View.VISIBLE
        binding.caption.visibility = if (photo == null || !captionShown || !single) View.GONE else View.VISIBLE
    }

    fun toggleCaption() {
        captionShown = !captionShown
        updateCaption()
    }

    // region Trash

    /** Out of sight at once; gone for real only once the undo has passed. */
    private fun throwAway(photo: CameraPhotos.Photo) {
        commitTrash()
        pendingTrash = photo
        refresh()
        undo = Snackbar.make(binding.root, R.string.photos_trashed, Snackbar.LENGTH_LONG)
            .setAction(R.string.photos_undo) {
                pendingTrash = null
                refresh()
                photos.indexOfFirst { it.key == photo.key }.takeIf { it >= 0 }?.let(pageLayout::scrollToPosition)
            }
            .addCallback(object : Snackbar.Callback() {
                override fun onDismissed(bar: Snackbar, event: Int) {
                    if (event != DISMISS_EVENT_ACTION) commitTrash()
                }
            })
            .also { it.show() }
    }

    private fun commitTrash() {
        val photo = pendingTrash ?: return
        pendingTrash = null
        CameraPhotos.trash(this, photo)
    }

    // endregion

    // region Selection

    private fun startSelection(photo: CameraPhotos.Photo) {
        selecting = true
        leaveSelection.isEnabled = true
        binding.root.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
        toggle(photo)
    }

    private fun toggle(photo: CameraPhotos.Photo) {
        if (!selected.remove(photo.key)) selected.add(photo.key)
        if (selected.isEmpty() && downloadingSelection == null) {
            endSelection()
            return
        }
        tiles.notifyItemRangeChanged(0, tiles.itemCount, SELECTION)
        updateSelectionBar()
    }

    /** Begins a drag selection from the tile at [position], selecting or deselecting as it did. */
    private fun startDrag(position: Int, photo: CameraPhotos.Photo) {
        dragAnchor = position
        dragLast = position
        dragSelects = photo.key in selected
        dragBase = selected.toSet()
    }

    private fun dragTo(x: Float, y: Float) {
        // Near the top or bottom edge the grid scrolls on by itself.
        val edge = resources.displayMetrics.density * 64
        when {
            y < edge -> binding.grid.scrollBy(0, -(edge - y).toInt() / 3)
            y > binding.grid.height - edge -> binding.grid.scrollBy(0, (y - binding.grid.height + edge).toInt() / 3)
        }
        val child = binding.grid.findChildViewUnder(x, y) ?: return
        val position = binding.grid.getChildAdapterPosition(child)
        if (position == RecyclerView.NO_POSITION || position == dragLast) return
        dragLast = position
        val range = (minOf(dragAnchor, position)..maxOf(dragAnchor, position)).mapNotNull { tiles.photoAt(it)?.key }
        selected.clear()
        selected.addAll(if (dragSelects) dragBase + range else dragBase - range.toSet())
        tiles.notifyItemRangeChanged(0, tiles.itemCount, SELECTION)
        updateSelectionBar()
    }

    private fun endSelection() {
        selecting = false
        selected.clear()
        leaveSelection.isEnabled = false
        tiles.notifyItemRangeChanged(0, tiles.itemCount, SELECTION)
        updateSelectionBar()
    }

    private fun updateSelectionBar() {
        binding.selectionBar.visibility = if (selecting) View.VISIBLE else View.GONE
        val progress = downloadingSelection
        binding.selectionCount.text = if (progress != null) {
            getString(R.string.photos_selection_downloading, progress.first + 1, progress.second)
        } else {
            getString(R.string.photos_selected, selected.size)
        }
        val chosen = selectedPhotos()
        binding.selectionDownload.isEnabled = progress == null && CameraPhotos.reachable && chosen.any { it.uri == null }
        binding.selectionDelete.isEnabled = progress == null && chosen.isNotEmpty()
        listOf(binding.selectionDownload, binding.selectionDelete).forEach { it.alpha = if (it.isEnabled) 1f else 0.38f }
    }

    private fun selectedPhotos() = photos.filter { it.key in selected }

    /** The selected pictures not on the phone yet, one after the other. */
    private fun downloadSelection() {
        val wanted = selectedPhotos().filter { it.uri == null }
        if (wanted.isEmpty()) return
        downloadingSelection = 0 to wanted.size
        updateSelectionBar()
        wanted.forEachIndexed { index, photo ->
            CameraPhotos.fetch(this, photo) {
                downloadingSelection = (index + 1) to wanted.size
                if (index == wanted.lastIndex) {
                    downloadingSelection = null
                    endSelection()
                } else {
                    updateSelectionBar()
                }
            }
        }
    }

    /** Asked first: off the camera's card there is no undo. */
    private fun confirmDeleteSelection() {
        val chosen = selectedPhotos()
        if (chosen.isEmpty()) return
        com.google.android.material.dialog.MaterialAlertDialogBuilder(this)
            .setTitle(getString(R.string.photos_delete_title, chosen.size))
            .setMessage(R.string.photos_delete_message)
            .setNegativeButton(R.string.photos_cancel, null)
            .setPositiveButton(R.string.photos_delete) { _, _ ->
                endSelection()
                chosen.forEach { CameraPhotos.trash(this, it) }
            }
            .show()
    }

    // endregion

    // region Single picture and grid

    /** From the picture to the tiles, the tiles growing into place around it. */
    private fun showGrid() {
        if (binding.grid.visibility == View.VISIBLE) return
        val key = currentPhoto()?.key
        tiles.positionOf(key)?.let { gridLayout.scrollToPositionWithOffset(it, binding.root.height / 3) }
        binding.grid.apply {
            alpha = 0f
            scaleX = 1.3f
            scaleY = 1.3f
            visibility = View.VISIBLE
            animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(ANIMATION_MS).start()
        }
        binding.pager.animate().alpha(0f).scaleX(0.85f).scaleY(0.85f).setDuration(ANIMATION_MS)
            .withEndAction { binding.pager.visibility = View.INVISIBLE }.start()
        updateCaption()
    }

    /** Back to one picture, [photo] or the one the grid was opened from. */
    private fun showPage(photo: CameraPhotos.Photo?) {
        photo?.let { chosen -> photos.indexOfFirst { it.key == chosen.key }.takeIf { it >= 0 }?.let(pageLayout::scrollToPosition) }
        binding.pager.apply {
            visibility = View.VISIBLE
            animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(ANIMATION_MS).start()
        }
        binding.grid.animate().alpha(0f).scaleX(1.3f).scaleY(1.3f).setDuration(ANIMATION_MS)
            .withEndAction { binding.grid.visibility = View.GONE }.start()
        binding.pager.post { updateCaption() }
    }

    private fun setSpan(columns: Int) {
        TransitionManager.beginDelayedTransition(binding.grid, ChangeBounds().setDuration(ANIMATION_MS))
        gridLayout.spanCount = columns
        tiles.notifyItemRangeChanged(0, tiles.itemCount)
    }

    // endregion

    private inner class Pages : RecyclerView.Adapter<Page>() {
        override fun getItemCount() = photos.size

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Page =
            Page(LayoutInflater.from(parent.context).inflate(R.layout.item_photo, parent, false))

        override fun onBindViewHolder(holder: Page, position: Int) = holder.bind(photos[position])
    }

    private inner class Page(view: View) : RecyclerView.ViewHolder(view) {
        private val image: ZoomImageView = view.findViewById(R.id.image)
        private val progress: ProgressBar = view.findViewById(R.id.progress)
        private val note: TextView = view.findViewById(R.id.note)
        private val onCamera: View = view.findViewById(R.id.onCamera)
        private var key: String? = null
        private var full = false
        /** The full picture was asked for; a refresh need not ask again. */
        private var requested = false

        init {
            image.onTap = { toggleCaption() }
            image.onPinchOut = { showGrid() }
            image.onSwipeUp = {
                photos.firstOrNull { it.key == key }?.let(::throwAway)
                image.translationY = 0f
                image.alpha = 1f
            }
        }

        fun bind(photo: CameraPhotos.Photo) {
            if (key == photo.key && (full || requested && photo.uri == null)) return
            if (key != photo.key) image.setImageDrawable(null)
            key = photo.key
            full = false
            requested = false
            image.translationY = 0f
            image.alpha = 1f
            note.visibility = View.GONE
            progress.visibility = View.VISIBLE
            onCamera.visibility = if (photo.uri == null) View.VISIBLE else View.GONE
            val uri = photo.uri
            if (uri != null) {
                show(photo.key, uri)
                return
            }
            CameraPhotos.thumbnail(this@PhotoViewerActivity, photo, urgent = true) { bytes ->
                if (key == photo.key && image.drawable == null && bytes != null) {
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.let(image::setImageBitmap)
                }
            }
            if (!CameraPhotos.reachable) {
                progress.visibility = View.GONE
                note.visibility = View.VISIBLE
                note.setText(R.string.photos_switch_camera_on)
                return
            }
            requested = true
            CameraPhotos.fetch(this@PhotoViewerActivity, photo) { fetched ->
                if (key != photo.key) return@fetch
                if (fetched != null) {
                    show(photo.key, fetched)
                } else {
                    progress.visibility = View.GONE
                    note.visibility = View.VISIBLE
                    note.setText(if (CameraPhotos.reachable) R.string.photos_download_failed else R.string.photos_switch_camera_on)
                }
            }
        }

        private fun show(forKey: String, uri: Uri) {
            runCatching {
                decoder.execute {
                    val bitmap = decode(uri, MAX_SIDE)
                    image.post {
                        if (key != forKey) return@post
                        progress.visibility = View.GONE
                        if (bitmap != null) {
                            full = true
                            onCamera.visibility = View.GONE
                            image.setImageBitmap(bitmap)
                        } else {
                            note.visibility = View.VISIBLE
                            note.setText(R.string.photos_download_failed)
                        }
                    }
                }
            }
        }
    }

    /** Day headers and the pictures under them, newest day first. */
    private inner class Tiles : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        private var rows: List<Any> = emptyList()

        fun build(photos: List<CameraPhotos.Photo>) {
            val list = mutableListOf<Any>()
            var day: Long? = null
            photos.forEach { photo ->
                val start = startOfDay(photo.taken)
                if (start != day) {
                    day = start
                    list.add(start)
                }
                list.add(photo)
            }
            rows = list
            notifyDataSetChanged()
        }

        fun isDay(position: Int) = rows.getOrNull(position) is Long

        fun photoAt(position: Int) = rows.getOrNull(position) as? CameraPhotos.Photo

        fun positionOf(key: String?): Int? =
            rows.indexOfFirst { (it as? CameraPhotos.Photo)?.key == key }.takeIf { it >= 0 }

        override fun getItemCount() = rows.size

        override fun getItemViewType(position: Int) = if (isDay(position)) DAY else TILE

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
            val inflater = LayoutInflater.from(parent.context)
            return if (viewType == DAY) {
                object : RecyclerView.ViewHolder(inflater.inflate(R.layout.item_day, parent, false)) {}
            } else {
                Tile(inflater.inflate(R.layout.item_tile, parent, false))
            }
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int, payloads: MutableList<Any>) {
            val row = rows[position]
            if (payloads.contains(SELECTION) && holder is Tile && row is CameraPhotos.Photo) {
                holder.showSelection(row)
            } else {
                onBindViewHolder(holder, position)
            }
        }

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            when (val row = rows[position]) {
                is Long -> (holder.itemView as TextView).text = dayLabel(row)
                is CameraPhotos.Photo -> (holder as Tile).bind(row)
            }
        }
    }

    private inner class Tile(view: View) : RecyclerView.ViewHolder(view) {
        private val image: ImageView = view.findViewById(R.id.tile)
        private val onCamera: View = view.findViewById(R.id.onCamera)
        private val check: View = view.findViewById(R.id.check)
        private val dim: View = view.findViewById(R.id.dim)
        private var key: String? = null

        fun showSelection(photo: CameraPhotos.Photo) {
            val chosen = photo.key in selected
            check.visibility = if (chosen) View.VISIBLE else View.GONE
            dim.visibility = if (chosen) View.VISIBLE else View.GONE
        }

        fun bind(photo: CameraPhotos.Photo) {
            key = photo.key
            onCamera.visibility = if (photo.uri == null) View.VISIBLE else View.GONE
            showSelection(photo)
            itemView.setOnClickListener { if (selecting) toggle(photo) else showPage(photo) }
            itemView.setOnLongClickListener {
                if (selecting) toggle(photo) else startSelection(photo)
                @Suppress("DEPRECATION") if (selecting) startDrag(adapterPosition, photo)
                true
            }
            val cached = thumbs.get(photo.key)
            image.setImageBitmap(cached)
            if (cached != null) return
            val uri = photo.uri
            if (uri != null) {
                runCatching {
                    decoder.execute {
                        val bitmap = runCatching { thumbnail(uri) }.getOrNull()
                        image.post { if (bitmap != null) deliver(photo.key, bitmap) }
                    }
                }
            } else {
                CameraPhotos.thumbnail(this@PhotoViewerActivity, photo) { bytes ->
                    bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }?.let { deliver(photo.key, it) }
                }
            }
        }

        private fun deliver(forKey: String, bitmap: Bitmap) {
            thumbs.put(forKey, bitmap)
            if (key == forKey) image.setImageBitmap(bitmap)
        }
    }

    /** The gallery's own small copy, quick to load for a grid of them. */
    private fun thumbnail(uri: Uri): Bitmap? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            contentResolver.loadThumbnail(uri, Size(THUMB_SIDE, THUMB_SIDE), null)
        } else {
            decode(uri, THUMB_SIDE)
        }

    private fun startOfDay(time: Long): Long = Calendar.getInstance().apply {
        timeInMillis = time
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    private fun dayLabel(day: Long): String =
        DateUtils.formatDateTime(this, day, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_WEEKDAY or DateUtils.FORMAT_SHOW_YEAR)

    /**
     * Large enough to zoom into, small enough to draw: a 40 MP original would
     * take 160 MB, past what a canvas accepts.
     */
    private fun decode(uri: Uri, longest: Int): Bitmap? = runCatching {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > longest) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val bitmap = contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
        bitmap?.let { rotate(uri, it) }
    }.getOrNull()

    /** The camera stores the orientation in EXIF; the pixels are always landscape. */
    private fun rotate(uri: Uri, bitmap: Bitmap): Bitmap {
        val degrees = contentResolver.openInputStream(uri)?.use {
            when (android.media.ExifInterface(it).getAttributeInt(
                android.media.ExifInterface.TAG_ORIENTATION, 1,
            )) {
                6 -> 90f
                3 -> 180f
                8 -> 270f
                else -> 0f
            }
        } ?: 0f
        if (degrees == 0f) return bitmap
        val matrix = android.graphics.Matrix().apply { postRotate(degrees) }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    companion object {
        /** Opened onto the tiles rather than the newest picture. */
        const val EXTRA_GRID = "grid"

        private const val MAX_SIDE = 4096
        private const val THUMB_SIDE = 384
        private const val THUMB_CACHE = 300
        /** Columns of the grid: large tiles, small ones, and the smallest. */
        private val TILE_SIZES = listOf(2, 4, 6)
        /** How far the fingers must close or open to change the tile size. */
        private const val PINCH_SMALLER = 0.65f
        private const val PINCH_LARGER = 1.55f
        private const val ANIMATION_MS = 220L
        private const val SELECTION = "selection"
        private const val DAY = 0
        private const val TILE = 1
    }
}

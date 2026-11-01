package pl.mwgo.macdroidsync

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.text.format.DateUtils
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ProgressBar
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.PagerSnapHelper
import androidx.recyclerview.widget.RecyclerView
import pl.mwgo.macdroidsync.databinding.ActivityPhotoViewerBinding
import java.util.concurrent.Executors

/**
 * The camera's pictures, newest first, one per screen: swipe for older ones,
 * pinch or double tap to zoom. A picture not imported yet is imported as soon
 * as it is shown, its small preview standing in meanwhile.
 */
class PhotoViewerActivity : ScreenActivity() {

    private lateinit var binding: ActivityPhotoViewerBinding
    private val adapter = Pages()
    private val decoder = Executors.newFixedThreadPool(2)
    private val layout by lazy { LinearLayoutManager(this, LinearLayoutManager.HORIZONTAL, false) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityPhotoViewerBinding.inflate(layoutInflater)
        setContentView(binding.root)
        useToolbar(binding.toolbar, showUp = true)
        binding.pager.layoutManager = layout
        binding.pager.adapter = adapter
        PagerSnapHelper().attachToRecyclerView(binding.pager)
        binding.pager.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrollStateChanged(view: RecyclerView, state: Int) {
                if (state == RecyclerView.SCROLL_STATE_IDLE) updateTitle()
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
    }

    override fun onDestroy() {
        super.onDestroy()
        decoder.shutdownNow()
    }

    private fun refresh() {
        val current = adapter.photos.getOrNull(layout.findFirstVisibleItemPosition())?.key
        adapter.photos = CameraPhotos.photos(this)
        adapter.notifyDataSetChanged()
        current?.let { key -> adapter.photos.indexOfFirst { it.key == key }.takeIf { it >= 0 }?.let(layout::scrollToPosition) }
        binding.emptyText.visibility = if (adapter.photos.isEmpty()) View.VISIBLE else View.GONE
        binding.emptyText.text = when (val state = CameraPhotos.state) {
            is CameraPhotos.State.Busy -> getString(state.step)
            is CameraPhotos.State.Failed -> state.reason
            else -> getString(R.string.photos_none)
        }
        updateTitle()
    }

    private fun updateTitle() {
        val position = layout.findFirstCompletelyVisibleItemPosition().takeIf { it >= 0 } ?: 0
        val photo = adapter.photos.getOrNull(position)
        supportActionBar?.title = photo?.filename ?: getString(R.string.title_photos)
        supportActionBar?.subtitle = photo?.takeIf { it.taken > 0 }?.let {
            DateUtils.formatDateTime(this, it.taken, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_TIME)
        }
    }

    private inner class Pages : RecyclerView.Adapter<Page>() {
        var photos: List<CameraPhotos.Photo> = emptyList()

        override fun getItemCount() = photos.size

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Page =
            Page(LayoutInflater.from(parent.context).inflate(R.layout.item_photo, parent, false))

        override fun onBindViewHolder(holder: Page, position: Int) = holder.bind(photos[position])
    }

    private inner class Page(view: View) : RecyclerView.ViewHolder(view) {
        private val image: ZoomImageView = view.findViewById(R.id.image)
        private val progress: ProgressBar = view.findViewById(R.id.progress)
        private val note: TextView = view.findViewById(R.id.note)
        private var key: String? = null
        private var full = false

        fun bind(photo: CameraPhotos.Photo) {
            if (key == photo.key && (full || photo.uri == null && image.drawable != null)) return
            key = photo.key
            full = false
            image.setImageDrawable(null)
            note.visibility = View.GONE
            val uri = photo.uri
            if (uri != null) {
                progress.visibility = View.VISIBLE
                show(photo.key, uri)
                return
            }
            progress.visibility = View.VISIBLE
            CameraPhotos.thumbnail(this@PhotoViewerActivity, photo) { bytes ->
                if (key == photo.key && image.drawable == null && bytes != null) {
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.let(image::setImageBitmap)
                }
            }
            CameraPhotos.fetch(this@PhotoViewerActivity, photo) { fetched ->
                if (key != photo.key) return@fetch
                if (fetched != null) {
                    show(photo.key, fetched)
                } else {
                    progress.visibility = View.GONE
                    note.visibility = View.VISIBLE
                    note.setText(R.string.photos_download_failed)
                }
            }
        }

        private fun show(forKey: String, uri: Uri) {
            val size = maxOf(resources.displayMetrics.widthPixels, resources.displayMetrics.heightPixels) * 2
            runCatching {
                decoder.execute {
                    val bitmap = decode(uri, size)
                    image.post {
                        if (key != forKey) return@post
                        progress.visibility = View.GONE
                        if (bitmap != null) {
                            full = true
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

    /** Large enough to zoom into, small enough not to run out of memory. */
    private fun decode(uri: Uri, longest: Int): Bitmap? = runCatching {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= longest) sample *= 2
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
}

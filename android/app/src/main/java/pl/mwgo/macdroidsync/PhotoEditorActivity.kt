package pl.mwgo.macdroidsync

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import androidx.exifinterface.media.ExifInterface
import android.net.Uri
import android.os.Bundle
import android.provider.MediaStore
import android.util.Log
import android.view.View
import android.view.animation.DecelerateInterpolator
import android.widget.TextView
import android.widget.Toast
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import pl.mwgo.macdroidsync.databinding.ActivityPhotoEditorBinding
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Crops and straightens one picture: the picture moves and zooms under a fixed
 * frame of its own or chosen proportions, the ruler turns it. Saved at the original's
 * resolution with its EXIF, either as a copy beside it or over it.
 */
class PhotoEditorActivity : ScreenActivity() {

    private lateinit var binding: ActivityPhotoEditorBinding
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var source: Uri
    /** Preview pixels to upright full size pixels. */
    private var previewFactor = 1f
    /** The picture as it is, upright; the frame shows it turned by [quarters]. */
    private var preview: Bitmap? = null
    /** Quarter turns clockwise from the buttons beside the ruler, 0 to 3. */
    private var quarters = 0
    private var turning = false
    private var landscape = false
    /** Which of [RATIOS] the frame has; -1 for proportions dragged freely. */
    private var chosen = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityPhotoEditorBinding.inflate(layoutInflater)
        setContentView(binding.root)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.statusBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        source = intent.data ?: return finish()

        // Upright, the bars have room of their own; on its side the picture takes
        // the screen and the controls float over it.
        landscape = resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
        val density = resources.displayMetrics.density
        binding.crop.insetTop = if (landscape) 0f else density * 64
        binding.crop.insetBottom = if (landscape) 0f else density * 130
        binding.ruler.onAngle = { angle, turning ->
            binding.crop.angle = angle
            binding.crop.showGrid = turning
        }
        // Out of the way while the picture is moved or zoomed, back once the finger lifts.
        binding.crop.onTouching = { touching ->
            for (bar in listOf(binding.turnBar, binding.ratioBar)) {
                bar.animate().cancel()
                bar.animate()
                    .alpha(if (touching) 0f else 1f)
                    .setStartDelay(if (touching) 0 else RULER_RETURN_DELAY_MS)
                    .setDuration(RULER_FADE_MS)
                    .start()
            }
        }
        binding.cancel.setOnClickListener { finish() }
        binding.aspect.setOnClickListener {
            if (binding.crop.free) setFree(false)
            showRatios(binding.ratioBar.visibility != View.VISIBLE)
        }
        binding.free.setOnClickListener { setFree(!binding.crop.free) }
        addRatios()
        binding.rotateLeft.setOnClickListener { turn(-1) }
        binding.rotateRight.setOnClickListener { turn(1) }
        binding.saveCopy.setOnClickListener { save(overwrite = false) }
        binding.save.setOnClickListener {
            // Over the original there is no way back on the phone.
            com.google.android.material.dialog.MaterialAlertDialogBuilder(this)
                .setTitle(R.string.editor_overwrite_title)
                .setMessage(R.string.editor_overwrite_message)
                .setNegativeButton(R.string.photos_cancel, null)
                .setPositiveButton(R.string.editor_overwrite) { _, _ -> save(overwrite = true) }
                .show()
        }

        binding.progress.visibility = View.VISIBLE
        worker.execute {
            val preview = runCatching { decodeUpright(source, PREVIEW_SIDE) }.getOrNull()
            runOnUiThread {
                binding.progress.visibility = View.GONE
                if (preview == null) {
                    Toast.makeText(this, R.string.editor_failed, Toast.LENGTH_LONG).show()
                    finish()
                } else {
                    previewFactor = uprightSize(source).let { it.first.toFloat() / preview.width }
                    this.preview = preview
                    binding.crop.show(preview)
                }
            }
        }
    }

    /** A quarter turn, shown turning: the frame and what it holds turn with the picture. */
    private fun turn(by: Int) {
        val upright = preview ?: return
        if (turning) return
        turning = true
        quarters = (quarters + by + 4) % 4
        val turned = if (quarters == 0) upright else Bitmap.createBitmap(
            upright, 0, 0, upright.width, upright.height, Matrix().apply { setRotate(quarters * 90f) }, true,
        )
        val crop = binding.crop
        val k = crop.turnScale()
        crop.frameCenter.let {
            crop.pivotX = it.x
            crop.pivotY = it.y
        }
        crop.animate()
            .rotation(by * 90f)
            .scaleX(k)
            .scaleY(k)
            .setDuration(TURN_MS)
            .setInterpolator(DecelerateInterpolator())
            .withEndAction {
                crop.rotation = 0f
                crop.scaleX = 1f
                crop.scaleY = 1f
                crop.turn(turned, clockwise = by > 0)
                // Chosen proportions turn with the picture: 3:2 becomes 2:3.
                if (chosen > 0) {
                    val upright = 1 / RATIOS[chosen].second!!
                    chosen = RATIOS.indexOfFirst { it.second != null && abs(it.second!! - upright) < 0.001f }
                }
                markChosen()
                turning = false
            }
            .start()
    }

    /**
     * Free proportions: the bars below go, and the frame keeps clear of the
     * screen's edges, so dragging its sides never starts a system swipe.
     */
    private fun setFree(on: Boolean) {
        val crop = binding.crop
        val density = resources.displayMetrics.density
        if (landscape) {
            crop.insetTop = if (on) density * 24 else 0f
            crop.insetBottom = if (on) density * 32 else 0f
            crop.insetEnd = if (on) (binding.actions?.width ?: 0) + density * 24 else 0f
        } else {
            crop.insetBottom = density * if (on) 56 else 130
        }
        crop.free = on
        if (on) {
            chosen = -1
            binding.turnBar.visibility = View.GONE
            binding.ratioBar.visibility = View.GONE
            binding.aspect.imageTintList = ColorStateList.valueOf(Color.WHITE)
        } else {
            showRatios(false)
        }
        markChosen()
    }

    /** The proportions in place of the ruler, or the ruler back. */
    private fun showRatios(show: Boolean) {
        binding.ratioBar.visibility = if (show) View.VISIBLE else View.GONE
        binding.turnBar.visibility = if (show) View.GONE else View.VISIBLE
        binding.aspect.imageTintList = ColorStateList.valueOf(if (show) ACCENT else Color.WHITE)
    }

    private fun addRatios() {
        val density = resources.displayMetrics.density
        RATIOS.forEachIndexed { index, (label, ratio) ->
            binding.ratios.addView(TextView(this).apply {
                text = if (ratio == null) getString(R.string.editor_original) else label
                textSize = 14f
                setPadding((density * 14).toInt(), (density * 10).toInt(), (density * 14).toInt(), (density * 10).toInt())
                setOnClickListener {
                    chosen = index
                    binding.crop.setRatio(ratio)
                    markChosen()
                }
            })
        }
        markChosen()
    }

    private fun markChosen() {
        for (i in 0 until binding.ratios.childCount) {
            (binding.ratios.getChildAt(i) as TextView).apply {
                setTextColor(if (i == chosen) ACCENT else Color.WHITE)
                setTypeface(null, if (i == chosen) Typeface.BOLD else Typeface.NORMAL)
            }
        }
        binding.free.imageTintList = ColorStateList.valueOf(if (binding.crop.free) ACCENT else Color.WHITE)
    }

    override fun onDestroy() {
        super.onDestroy()
        worker.shutdown()
    }

    private fun save(overwrite: Boolean) {
        val crop = binding.crop.crop() ?: return
        binding.save.isEnabled = false
        binding.saveCopy.isEnabled = false
        binding.progress.visibility = View.VISIBLE
        worker.execute {
            val saved = runCatching { render(crop, overwrite) }
                .onFailure { Log.w(Prefs.TAG, "Saving the edit failed", it) }
                .getOrNull()
            runOnUiThread {
                binding.progress.visibility = View.GONE
                if (saved == null) {
                    binding.save.isEnabled = true
                    binding.saveCopy.isEnabled = true
                    Toast.makeText(this, R.string.editor_failed, Toast.LENGTH_LONG).show()
                } else {
                    Toast.makeText(this, if (overwrite) R.string.editor_overwritten else R.string.editor_saved, Toast.LENGTH_SHORT).show()
                    setResult(RESULT_OK, Intent().setData(saved))
                    finish()
                }
            }
        }
    }

    /**
     * The frame's content at the original's own resolution: the picture decoded
     * whole, set upright, turned and cut in one draw. Halved only when the
     * memory would not hold the original and the result together.
     */
    private fun render(crop: CropView.Crop, overwrite: Boolean): Uri {
        val (uprightW, uprightH) = uprightSize(source)
        val outW = (crop.width * previewFactor).roundToInt()
        val outH = (crop.height * previewFactor).roundToInt()
        var sample = 1
        val budget = Runtime.getRuntime().maxMemory() * 0.7
        while ((uprightW.toLong() * uprightH / (sample * sample) + outW.toLong() * outH / (sample * sample)) * 4 > budget) sample *= 2

        val raw = contentResolver.openInputStream(source)!!.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: throw IllegalStateException("could not decode")
        val f = previewFactor / sample
        val output = Bitmap.createBitmap(outW / sample, outH / sample, Bitmap.Config.ARGB_8888)
        val matrix = uprightMatrix(raw.width, raw.height, orientation(source)).apply {
            // Then the quarter turns, the result moved back to the origin.
            if (quarters != 0) {
                val bounds = RectF(0f, 0f, raw.width.toFloat(), raw.height.toFloat()).also { mapRect(it) }
                postRotate(quarters * 90f)
                val turned = RectF(bounds).also { Matrix().apply { setRotate(quarters * 90f) }.mapRect(it) }
                postTranslate(-turned.left, -turned.top)
            }
            // Upright pixels to the output: the crop's centre to the output's,
            // turned as the picture was turned under the frame.
            postTranslate(-crop.center.x * f, -crop.center.y * f)
            postRotate(crop.angle)
            postTranslate(output.width / 2f, output.height / 2f)
        }
        Canvas(output).drawBitmap(raw, matrix, Paint(Paint.FILTER_BITMAP_FLAG))
        raw.recycle()
        return (if (overwrite) overwrite(output) else store(output)).also { output.recycle() }
    }

    /** Into the original's own file, its EXIF read before it is replaced. */
    private fun overwrite(bitmap: Bitmap): Uri {
        val exif = readExif(source)
        contentResolver.openOutputStream(source, "wt")!!.use { bitmap.compress(Bitmap.CompressFormat.JPEG, QUALITY, it) }
        writeExif(exif, source, bitmap.width, bitmap.height)
        return source
    }

    /** Next to the original, named after it, with its EXIF and now upright. */
    private fun store(bitmap: Bitmap): Uri {
        val (name, folder, taken) = describe(source)
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, editName(name))
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(MediaStore.Images.Media.RELATIVE_PATH, folder)
            put(MediaStore.Images.Media.IS_PENDING, 1)
            if (taken > 0) put(MediaStore.Images.Media.DATE_TAKEN, taken)
        }
        val uri = contentResolver.insert(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)
            ?: throw IllegalStateException("MediaStore refused the edit")
        try {
            contentResolver.openOutputStream(uri)!!.use { bitmap.compress(Bitmap.CompressFormat.JPEG, QUALITY, it) }
            writeExif(readExif(source), uri, bitmap.width, bitmap.height)
            contentResolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
        } catch (error: Exception) {
            contentResolver.delete(uri, null, null)
            throw error
        }
        CameraPhotos.addEdit(this, uri, editName(name), taken)
        return uri
    }

    private fun readExif(from: Uri): Map<String, String> {
        val original = contentResolver.openInputStream(from)?.use { ExifInterface(it) } ?: return emptyMap()
        return EXIF_TAGS.mapNotNull { tag -> original.getAttribute(tag)?.let { tag to it } }.toMap()
    }

    private fun writeExif(exif: Map<String, String>, to: Uri, width: Int, height: Int) {
        contentResolver.openFileDescriptor(to, "rw")?.use { descriptor ->
            val edited = ExifInterface(descriptor.fileDescriptor)
            exif.forEach { (tag, value) -> edited.setAttribute(tag, value) }
            edited.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL.toString())
            edited.setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, width.toString())
            edited.setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, height.toString())
            edited.setAttribute(ExifInterface.TAG_SOFTWARE, getString(R.string.app_name))
            edited.saveAttributes()
        }
    }

    private fun editName(name: String): String {
        val dot = name.lastIndexOf('.')
        return if (dot > 0) name.substring(0, dot) + "_edit" + name.substring(dot) else name + "_edit.jpg"
    }

    private fun describe(uri: Uri): Triple<String, String, Long> {
        val columns = arrayOf(
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.RELATIVE_PATH,
            MediaStore.Images.Media.DATE_TAKEN,
        )
        contentResolver.query(uri, columns, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                return Triple(cursor.getString(0) ?: "edit.jpg", cursor.getString(1) ?: "Pictures/", cursor.getLong(2))
            }
        }
        return Triple("edit.jpg", "Pictures/", 0L)
    }

    private fun orientation(uri: Uri): Int = contentResolver.openInputStream(uri)?.use {
        ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
    } ?: ExifInterface.ORIENTATION_NORMAL

    private fun degrees(orientation: Int) = when (orientation) {
        ExifInterface.ORIENTATION_ROTATE_90 -> 90f
        ExifInterface.ORIENTATION_ROTATE_180 -> 180f
        ExifInterface.ORIENTATION_ROTATE_270 -> 270f
        else -> 0f
    }

    /** The picture's size once its EXIF orientation is applied. */
    private fun uprightSize(uri: Uri): Pair<Int, Int> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        val turned = degrees(orientation(uri)) % 180 != 0f
        return if (turned) bounds.outHeight to bounds.outWidth else bounds.outWidth to bounds.outHeight
    }

    /** Raw pixels to upright ones, the turned picture moved back to the origin. */
    private fun uprightMatrix(width: Int, height: Int, orientation: Int): Matrix {
        val matrix = Matrix().apply { setRotate(degrees(orientation)) }
        val bounds = RectF(0f, 0f, width.toFloat(), height.toFloat())
        matrix.mapRect(bounds)
        matrix.postTranslate(-bounds.left, -bounds.top)
        return matrix
    }

    /** A smaller upright copy to edit on screen. */
    private fun decodeUpright(uri: Uri, longest: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > longest) sample *= 2
        val raw = contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: return null
        val matrix = uprightMatrix(raw.width, raw.height, orientation(uri))
        if (matrix.isIdentity) return raw
        return Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, Matrix().apply { setRotate(degrees(orientation(uri))) }, true)
    }

    companion object {
        private const val PREVIEW_SIDE = 3000
        private const val RULER_FADE_MS = 220L
        private const val RULER_RETURN_DELAY_MS = 350L
        private const val QUALITY = 95
        private const val TURN_MS = 300L
        private val ACCENT = Color.rgb(0xFF, 0xC1, 0x07)
        /** Frame proportions offered, each with its upright twin; null for the picture's own. */
        private val RATIOS = listOf<Pair<String, Float?>>(
            "" to null, "1:1" to 1f,
            "3:2" to 3f / 2, "2:3" to 2f / 3,
            "4:3" to 4f / 3, "3:4" to 3f / 4,
            "16:9" to 16f / 9, "9:16" to 9f / 16,
            "5:4" to 5f / 4, "4:5" to 4f / 5,
        )

        /** What the copy keeps of the original's EXIF: when, with what, and where. */
        private val EXIF_TAGS = listOf(
            ExifInterface.TAG_DATETIME, ExifInterface.TAG_DATETIME_ORIGINAL, ExifInterface.TAG_DATETIME_DIGITIZED,
            ExifInterface.TAG_OFFSET_TIME, ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
            ExifInterface.TAG_MAKE, ExifInterface.TAG_MODEL, ExifInterface.TAG_LENS_MAKE, ExifInterface.TAG_LENS_MODEL, ExifInterface.TAG_LENS_SPECIFICATION,
            ExifInterface.TAG_EXPOSURE_TIME, ExifInterface.TAG_F_NUMBER, ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY, ExifInterface.TAG_SENSITIVITY_TYPE,
            ExifInterface.TAG_FOCAL_LENGTH, ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM, ExifInterface.TAG_EXPOSURE_BIAS_VALUE,
            ExifInterface.TAG_EXPOSURE_PROGRAM, ExifInterface.TAG_METERING_MODE, ExifInterface.TAG_FLASH,
            ExifInterface.TAG_WHITE_BALANCE, ExifInterface.TAG_ARTIST, ExifInterface.TAG_COPYRIGHT,
            ExifInterface.TAG_GPS_LATITUDE, ExifInterface.TAG_GPS_LATITUDE_REF,
            ExifInterface.TAG_GPS_LONGITUDE, ExifInterface.TAG_GPS_LONGITUDE_REF,
            ExifInterface.TAG_GPS_ALTITUDE, ExifInterface.TAG_GPS_ALTITUDE_REF,
            ExifInterface.TAG_GPS_TIMESTAMP, ExifInterface.TAG_GPS_DATESTAMP,
        )

        fun intent(context: Context, uri: Uri): Intent = Intent(context, PhotoEditorActivity::class.java).setData(uri)
    }
}

package pl.wojas.macdroidsync

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.net.Uri
import java.io.File
import java.util.UUID
import kotlin.math.max

/**
 * The pictures of the notes, kept as JPEG files in the app's own storage under
 * notes/images. A note refers to one by its path relative to notes/.
 */
class NoteImages(context: Context) {

    private val resolver = context.contentResolver
    private val folder = File(context.filesDir, "notes")

    /**
     * Copies the picture at [uri] in, at most [MAX_SIDE] pixels on its long
     * side. ImageDecoder turns it upright from its EXIF orientation, so the
     * file needs none. Slow enough to be kept off the main thread.
     */
    fun import(uri: Uri): MdImage? = runCatching {
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
            val side = max(info.size.width, info.size.height)
            decoder.setTargetSampleSize(((side + MAX_SIDE - 1) / MAX_SIDE).coerceAtLeast(1))
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
        val path = "images/${UUID.randomUUID()}.jpg"
        val file = File(folder, path)
        file.parentFile?.mkdirs()
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, it) }
        bitmap.recycle()
        MdImage(path)
    }.getOrNull()

    /**
     * Keeps a drawing as a PNG picture of the notes, with its strokes beside
     * it in a JSON file of the same name, so that it can be drawn on again.
     * [into] is the drawing being changed, or null for a new one. Slow enough
     * to be kept off the main thread.
     */
    fun saveDrawing(bitmap: Bitmap, strokes: String, alt: String, into: MdImage?): MdImage? = runCatching {
        val image = into ?: MdImage("images/${UUID.randomUUID()}.png", alt)
        val file = File(folder, image.path)
        file.parentFile?.mkdirs()
        val next = File(file.path + ".new")
        next.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        next.renameTo(file)
        strokesFile(image).writeText(strokes)
        image
    }.getOrNull()

    /** The strokes of a drawing, or null for a photo, or a drawing turned since, which no longer matches them. */
    fun drawing(image: MdImage): String? = strokesFile(image).takeIf { it.isFile }?.readText()

    /** Removes the picture's files, the strokes of a drawing included. */
    fun delete(image: MdImage) {
        File(folder, image.path).delete()
        strokesFile(image).delete()
    }

    private fun strokesFile(image: MdImage) = File(folder, image.path.substringBeforeLast('.') + ".json")

    /** [bitmap] turned by [degrees], 90 being a quarter clockwise. */
    fun turned(bitmap: Bitmap, degrees: Int): Bitmap =
        Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, Matrix().apply { postRotate(degrees.toFloat()) }, true)

    /** Writes [bitmap] over the picture's file. Slow enough to be kept off the main thread. */
    fun save(image: MdImage, bitmap: Bitmap) {
        val file = File(folder, image.path)
        val next = File(file.path + ".new")
        val format = if (file.extension.equals("png", ignoreCase = true)) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
        next.outputStream().use { bitmap.compress(format, JPEG_QUALITY, it) }
        next.renameTo(file)
        // Its strokes would draw it the old way round; it stays a picture from now on.
        strokesFile(image).delete()
    }

    /** Reads a picture no smaller than [width] pixels wide where the file allows, or null when it is missing. */
    fun load(image: MdImage, width: Int): Bitmap? {
        val file = File(folder, image.path)
        if (!file.isFile) return null
        return runCatching {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
                decoder.setTargetSampleSize((info.size.width / width.coerceAtLeast(1)).coerceAtLeast(1))
                // A software bitmap can be turned and written back; a hardware one cannot everywhere.
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        }.getOrNull()
    }

    private companion object {
        const val MAX_SIDE = 2048
        const val JPEG_QUALITY = 88
    }
}

package pl.wojas.macdroidsync

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream

/** Shrinks a picture until it fits in one MMS. */
object MmsImage {

    /** Longest sides tried, largest first, each at falling JPEG quality. */
    private val SIDES = intArrayOf(1600, 1280, 1024, 800, 640, 480)
    private val QUALITIES = intArrayOf(85, 70, 55)

    fun fit(image: ByteArray, maxBytes: Int): ByteArray? {
        if (image.size <= maxBytes && isJpeg(image)) return image
        val source = BitmapFactory.decodeByteArray(image, 0, image.size) ?: return null
        try {
            for (side in SIDES) {
                val scaled = scale(source, side)
                try {
                    for (quality in QUALITIES) {
                        val out = ByteArrayOutputStream()
                        scaled.compress(Bitmap.CompressFormat.JPEG, quality, out)
                        if (out.size() <= maxBytes) return out.toByteArray()
                    }
                } finally {
                    if (scaled !== source) scaled.recycle()
                }
            }
            return null
        } finally {
            source.recycle()
        }
    }

    private fun scale(bitmap: Bitmap, side: Int): Bitmap {
        val longest = maxOf(bitmap.width, bitmap.height)
        if (longest <= side) return bitmap
        val factor = side.toFloat() / longest
        return Bitmap.createScaledBitmap(
            bitmap,
            (bitmap.width * factor).toInt().coerceAtLeast(1),
            (bitmap.height * factor).toInt().coerceAtLeast(1),
            true,
        )
    }

    private fun isJpeg(bytes: ByteArray): Boolean =
        bytes.size > 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte()
}

package pl.mwgo.macdroidsync

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.RectF
import android.util.AttributeSet
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import androidx.appcompat.widget.AppCompatImageView

/**
 * A picture that fits the screen and zooms with two fingers or a double tap.
 * Zoomed in, it keeps the swipe to itself for panning; at the fitted size the
 * swipe goes to the pager around it.
 */
class ZoomImageView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) :
    AppCompatImageView(context, attrs) {

    private val drawMatrix = Matrix()
    private var fitScale = 1f
    private var scale = 1f

    private val scaler = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            zoomBy(detector.scaleFactor, detector.focusX, detector.focusY)
            return true
        }
    })

    private val gestures = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDoubleTap(event: MotionEvent): Boolean {
            if (scale > 1.05f) reset() else zoomBy(DOUBLE_TAP_ZOOM, event.x, event.y)
            return true
        }

        override fun onScroll(first: MotionEvent?, event: MotionEvent, dx: Float, dy: Float): Boolean {
            if (scale <= 1.01f) return false
            drawMatrix.postTranslate(-dx, -dy)
            clamp()
            return true
        }
    })

    init {
        scaleType = ScaleType.MATRIX
    }

    override fun setImageBitmap(bitmap: Bitmap?) {
        super.setImageBitmap(bitmap)
        post { reset() }
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        reset()
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        scaler.onTouchEvent(event)
        gestures.onTouchEvent(event)
        parent?.requestDisallowInterceptTouchEvent(scale > 1.01f || event.pointerCount > 1)
        return true
    }

    /** Back to the whole picture, centred. */
    fun reset() {
        val image = drawable ?: return
        if (width == 0 || height == 0) return
        val w = image.intrinsicWidth.toFloat()
        val h = image.intrinsicHeight.toFloat()
        fitScale = minOf(width / w, height / h)
        scale = 1f
        drawMatrix.reset()
        drawMatrix.postScale(fitScale, fitScale)
        drawMatrix.postTranslate((width - w * fitScale) / 2, (height - h * fitScale) / 2)
        imageMatrix = drawMatrix
    }

    private fun zoomBy(factor: Float, x: Float, y: Float) {
        val target = (scale * factor).coerceIn(1f, MAX_ZOOM)
        val applied = target / scale
        scale = target
        drawMatrix.postScale(applied, applied, x, y)
        clamp()
    }

    /** No empty band beside a picture larger than the view; a smaller one stays centred. */
    private fun clamp() {
        val image = drawable ?: return
        val bounds = RectF(0f, 0f, image.intrinsicWidth.toFloat(), image.intrinsicHeight.toFloat())
        drawMatrix.mapRect(bounds)
        val dx = when {
            bounds.width() <= width -> (width - bounds.width()) / 2 - bounds.left
            bounds.left > 0 -> -bounds.left
            bounds.right < width -> width - bounds.right
            else -> 0f
        }
        val dy = when {
            bounds.height() <= height -> (height - bounds.height()) / 2 - bounds.top
            bounds.top > 0 -> -bounds.top
            bounds.bottom < height -> height - bounds.bottom
            else -> 0f
        }
        drawMatrix.postTranslate(dx, dy)
        imageMatrix = drawMatrix
    }

    private companion object {
        const val MAX_ZOOM = 8f
        const val DOUBLE_TAP_ZOOM = 3f
    }
}

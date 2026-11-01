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
 * sideways swipe goes to the pager around it, an upward one throws the picture
 * away, and pinching further in asks for the grid.
 */
class ZoomImageView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) :
    AppCompatImageView(context, attrs) {

    private val drawMatrix = Matrix()
    private var fitScale = 1f
    private var scale = 1f

    /** A single tap, told apart from the first half of a double tap. */
    var onTap: (() -> Unit)? = null

    /** The picture flicked or dragged upwards at its fitted size. */
    var onSwipeUp: (() -> Unit)? = null

    /** Two fingers pinched in while the whole picture already shows. */
    var onPinchOut: (() -> Unit)? = null

    private var pinchBelowFit = 1f
    /** Only a pinch begun on the whole picture leads to the grid, not one zooming back out. */
    private var pinchFromFit = false
    private var dragging = false

    private val scaler = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
            pinchBelowFit = 1f
            pinchFromFit = scale <= 1.01f
            return true
        }

        override fun onScale(detector: ScaleGestureDetector): Boolean {
            if (pinchFromFit && scale <= 1.01f && detector.scaleFactor < 1f) {
                pinchBelowFit *= detector.scaleFactor
                if (pinchBelowFit < PINCH_TO_GRID) {
                    pinchBelowFit = 0f
                    onPinchOut?.invoke()
                }
                if (pinchBelowFit != 0f) return true
            }
            zoomBy(detector.scaleFactor, detector.focusX, detector.focusY)
            return true
        }
    })

    private val gestures = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onSingleTapConfirmed(event: MotionEvent): Boolean {
            onTap?.invoke()
            return true
        }

        override fun onDoubleTap(event: MotionEvent): Boolean {
            if (scale > 1.05f) reset() else zoomBy(DOUBLE_TAP_ZOOM, event.x, event.y)
            return true
        }

        override fun onScroll(first: MotionEvent?, event: MotionEvent, dx: Float, dy: Float): Boolean {
            if (scale <= 1.01f) {
                // Upwards only, and clearly more up than sideways, which is the pager's.
                val start = first ?: return false
                val up = start.y - event.y
                if (!dragging && (up < touchSlop || up < kotlin.math.abs(start.x - event.x) * 1.5f)) return false
                dragging = true
                translationY = -maxOf(0f, up)
                alpha = 1f - (translationY / -height).coerceIn(0f, 0.6f)
                return true
            }
            drawMatrix.postTranslate(-dx, -dy)
            clamp()
            return true
        }

        override fun onFling(first: MotionEvent?, event: MotionEvent, vx: Float, vy: Float): Boolean {
            if (scale > 1.01f || vy > -FLING_UP || kotlin.math.abs(vy) < kotlin.math.abs(vx) * 1.5f) return false
            throwUp()
            return true
        }
    })

    private val touchSlop = android.view.ViewConfiguration.get(context).scaledTouchSlop

    /** Up and out of sight, then the owner decides what that means. */
    private fun throwUp() {
        dragging = false
        animate().translationY(-height.toFloat()).alpha(0f).setDuration(180).withEndAction { onSwipeUp?.invoke() }.start()
    }

    /** Back into place, after an undo or a drag that did not go far enough. */
    fun settle() {
        dragging = false
        animate().translationY(0f).alpha(1f).setDuration(180).start()
    }

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
        val handled = gestures.onTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
            if (dragging && !handled) {
                if (-translationY > height * THROW_FRACTION) throwUp() else settle()
            }
        }
        parent?.requestDisallowInterceptTouchEvent(scale > 1.01f || event.pointerCount > 1 || dragging)
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
        const val PINCH_TO_GRID = 0.75f
        const val FLING_UP = 2500f
        const val THROW_FRACTION = 0.3f
    }
}

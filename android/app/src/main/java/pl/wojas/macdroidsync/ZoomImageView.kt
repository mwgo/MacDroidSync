package pl.wojas.macdroidsync

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.RectF
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.animation.PathInterpolator
import android.widget.ImageView

/**
 * A picture fitted to the view that can be pinched to zoom, dragged while
 * zoomed, and double tapped to zoom in on a spot or back out. A single tap is
 * handed to [onSingleTap]. The fit is the same as FIT_CENTER, so animating the
 * view itself (scale, translation) works as it would on a plain ImageView.
 */
class ZoomImageView(context: Context) : ImageView(context) {

    var onSingleTap: (() -> Unit)? = null

    private val fit = Matrix()
    private val zoom = Matrix()
    private val shown = Matrix()
    private var bitmap: Bitmap? = null
    private var animator: ValueAnimator? = null
    private val easing = PathInterpolator(0.2f, 0f, 0f, 1f)

    val isZoomed get() = zoomScale() > 1.01f

    init {
        scaleType = ScaleType.MATRIX
    }

    override fun setImageBitmap(bm: Bitmap?) {
        super.setImageBitmap(bm)
        bitmap = bm
        animator?.cancel()
        zoom.reset()
        refit()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        refit()
    }

    private fun refit() {
        val b = bitmap ?: return
        if (width == 0 || height == 0) return
        fit.setRectToRect(
            RectF(0f, 0f, b.width.toFloat(), b.height.toFloat()),
            RectF(0f, 0f, width.toFloat(), height.toFloat()),
            Matrix.ScaleToFit.CENTER,
        )
        show()
    }

    private fun show() {
        shown.set(fit)
        shown.postConcat(zoom)
        imageMatrix = shown
    }

    private fun zoomScale(): Float {
        val values = FloatArray(9)
        zoom.getValues(values)
        return values[Matrix.MSCALE_X]
    }

    /** Keeps a zoomed picture covering the view, and a picture smaller than the view centred in it. */
    private fun keepInside() {
        val b = bitmap ?: return
        val m = Matrix(fit).apply { postConcat(zoom) }
        val rect = RectF(0f, 0f, b.width.toFloat(), b.height.toFloat()).also(m::mapRect)
        val dx = when {
            rect.width() <= width -> width / 2f - rect.centerX()
            rect.left > 0 -> -rect.left
            rect.right < width -> width - rect.right
            else -> 0f
        }
        val dy = when {
            rect.height() <= height -> height / 2f - rect.centerY()
            rect.top > 0 -> -rect.top
            rect.bottom < height -> height - rect.bottom
            else -> 0f
        }
        zoom.postTranslate(dx, dy)
    }

    /** Back to the plain fit, gliding there when [animated]. */
    fun resetZoom(animated: Boolean) {
        if (!animated) {
            animator?.cancel()
            zoom.reset()
            show()
            return
        }
        glideTo(Matrix())
    }

    private fun glideTo(target: Matrix) {
        animator?.cancel()
        val from = FloatArray(9).also(zoom::getValues)
        val to = FloatArray(9).also(target::getValues)
        val now = FloatArray(9)
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 240
            interpolator = easing
            addUpdateListener {
                val t = it.animatedValue as Float
                for (i in 0 until 9) now[i] = from[i] + (to[i] - from[i]) * t
                zoom.setValues(now)
                show()
            }
            start()
        }
    }

    private val pinch = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            animator?.cancel()
            val current = zoomScale()
            val factor = (current * detector.scaleFactor).coerceIn(MIN_ZOOM, MAX_ZOOM) / current
            zoom.postScale(factor, factor, detector.focusX, detector.focusY)
            keepInside()
            show()
            return true
        }

        override fun onScaleEnd(detector: ScaleGestureDetector) {
            // Pinched below the fit: spring back to it.
            if (zoomScale() < 1f) resetZoom(animated = true)
        }
    })

    private val gestures = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent) = true

        override fun onScroll(e1: MotionEvent?, e2: MotionEvent, distanceX: Float, distanceY: Float): Boolean {
            if (!isZoomed || pinch.isInProgress) return false
            zoom.postTranslate(-distanceX, -distanceY)
            keepInside()
            show()
            return true
        }

        override fun onDoubleTap(e: MotionEvent): Boolean {
            if (isZoomed) {
                resetZoom(animated = true)
            } else {
                val target = Matrix(zoom).apply { postScale(DOUBLE_TAP_ZOOM, DOUBLE_TAP_ZOOM, e.x, e.y) }
                val saved = Matrix(zoom)
                zoom.set(target)
                keepInside()
                target.set(zoom)
                zoom.set(saved)
                glideTo(target)
            }
            return true
        }

        override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
            if (isZoomed) resetZoom(animated = true) else onSingleTap?.invoke()
            return true
        }
    })

    override fun onTouchEvent(event: MotionEvent): Boolean {
        pinch.onTouchEvent(event)
        gestures.onTouchEvent(event)
        return true
    }

    private companion object {
        const val MIN_ZOOM = 0.7f
        const val MAX_ZOOM = 6f
        const val DOUBLE_TAP_ZOOM = 2.5f
    }
}

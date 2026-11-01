package pl.mwgo.macdroidsync

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.Rect
import android.graphics.RectF
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.animation.DecelerateInterpolator
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin

/**
 * A picture under a fixed thin frame. Pinching and dragging the picture choose
 * what the frame keeps; [angle] turns it under the frame. The picture always
 * covers the frame, growing as much as a turn needs. The frame takes the
 * picture's proportions or chosen ones, or, while [free], its edges are dragged.
 */
class CropView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {

    /** What the frame keeps, in the picture's own pixels, for the full size render. */
    data class Crop(val center: PointF, val width: Float, val height: Float, val angle: Float)

    var bitmap: Bitmap? = null
        private set

    /** Width to height of the frame; null for the picture's own. */
    private var ratio: Float? = null

    /** Degrees, clockwise; set by the ruler. */
    var angle = 0f
        set(value) {
            field = value
            fit()
            invalidate()
        }

    /** The fine grid, shown while the picture is being turned. */
    var showGrid = false
        set(value) {
            field = value
            editing = value
            invalidate()
        }

    /**
     * The frame's edges and corners can be dragged to any proportions. The frame
     * then keeps well away from the screen's sides, where the system's swipes start.
     */
    var free = false
        set(value) {
            if (field == value) return
            field = value
            if (bitmap != null && width > 0) settle()
            invalidate()
        }

    /**
     * While a finger moves the picture, what lies outside the frame shows
     * through, so the rest of the picture can be seen; at rest it is dimmed.
     */
    private var editing = false
        set(value) {
            if (field == value) return
            field = value
            shadeFade?.cancel()
            shadeFade = ValueAnimator.ofInt(shadePaint.alpha, if (value) SHADE_EDITING else SHADE_RESTING).apply {
                duration = 180
                addUpdateListener {
                    shadePaint.alpha = it.animatedValue as Int
                    invalidate()
                }
                start()
            }
        }
    private var shadeFade: ValueAnimator? = null
    private var frameMove: ValueAnimator? = null

    /** A finger on the picture itself, moving or zooming it, or lifted again. */
    var onTouching: ((Boolean) -> Unit)? = null

    /** Room the bars above and below the frame need, in pixels. */
    var insetTop = 0f
    var insetBottom = 0f
    /** Room controls on the right take over the picture, in pixels. */
    var insetEnd = 0f

    private val frame = RectF()
    private var scale = 1f
    private val offset = PointF()
    private val drawMatrix = Matrix()
    private val density = resources.displayMetrics.density
    /** Which of the frame's edges a finger holds, [LEFT] to [BOTTOM]; 0 for none. */
    private var edges = 0
    private val last = PointF()

    private val framePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = Color.argb(150, 255, 255, 255)
        strokeWidth = density
    }
    private val handlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = Color.WHITE
        strokeWidth = density * 3
        strokeCap = Paint.Cap.SQUARE
    }
    private val gridPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = Color.argb(90, 255, 255, 255)
        strokeWidth = density * 0.6f
    }
    private val shadePaint = Paint().apply { color = Color.argb(SHADE_RESTING, 0, 0, 0) }
    private val shade = Path().apply { fillType = Path.FillType.EVEN_ODD }

    private val scaler = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            val before = scale
            scale = (scale * detector.scaleFactor).coerceAtMost(minScale() * MAX_ZOOM)
            // Around the fingers: the point under them stays under them.
            val ratio = scale / before
            offset.x = (offset.x + frame.centerX() - detector.focusX) * ratio + detector.focusX - frame.centerX()
            offset.y = (offset.y + frame.centerY() - detector.focusY) * ratio + detector.focusY - frame.centerY()
            fit()
            invalidate()
            return true
        }
    })

    /**
     * The picture follows the fingers' midpoint, taken afresh whenever a finger
     * lands or lifts, so it never jumps when a pinch begins or ends.
     */
    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                finishFrameMove()
                edges = if (free) edgesAt(event.x, event.y) else 0
                last.set(event.x, event.y)
                editing = true
                onTouching?.invoke(true)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                scaler.onTouchEvent(event)
                if (edges != 0) {
                    edges = 0
                    settle()
                }
                editing = false
                onTouching?.invoke(false)
                return true
            }
        }
        if (edges != 0) {
            if (event.actionMasked == MotionEvent.ACTION_MOVE) {
                drag(event.x - last.x, event.y - last.y)
                last.set(event.x, event.y)
            }
            return true
        }
        scaler.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_POINTER_UP -> last.set(focus(event))
            MotionEvent.ACTION_MOVE -> {
                val now = focus(event)
                offset.x += now.x - last.x
                offset.y += now.y - last.y
                last.set(now)
                fit()
                invalidate()
            }
        }
        return true
    }

    /** The midpoint of the fingers staying down. */
    private fun focus(event: MotionEvent): PointF {
        val lifting = if (event.actionMasked == MotionEvent.ACTION_POINTER_UP) event.actionIndex else -1
        var x = 0f
        var y = 0f
        var count = 0
        for (i in 0 until event.pointerCount) {
            if (i == lifting) continue
            x += event.getX(i)
            y += event.getY(i)
            count++
        }
        return PointF(x / count, y / count)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        layoutFrame()
        fit()
    }

    /** A new picture, whole and straight in a frame of its own proportions. */
    fun show(image: Bitmap) {
        bitmap = image
        ratio = null
        layoutFrame()
        angle = 0f
        scale = minScale()
        offset.set(0f, 0f)
        fit()
        invalidate()
    }

    /**
     * Frame proportions, width to height, or null for the picture's own. The
     * frame eases into them, the picture as zoomed into it as it was before.
     */
    fun setRatio(value: Float?) {
        val image = bitmap ?: return
        ratio = value
        val zoom = scale / minScale()
        val startScale = scale
        val start = PointF(offset.x, offset.y)
        moveFrame(target(value ?: (image.width.toFloat() / image.height))) {
            scale = zoom * minScale()
            offset.set(start.x * scale / startScale, start.y * scale / startScale)
        }
    }

    val frameCenter get() = PointF(frame.centerX(), frame.centerY())

    /** How much bigger the frame shows once turned a quarter, the room being what it is. */
    fun turnScale(): Float = target(frame.height() / frame.width()).width() / frame.height()

    /**
     * The same picture a quarter turn on: what the frame held, it holds turned,
     * at the scale [turnScale] gives, its straightening kept.
     */
    fun turn(turned: Bitmap, clockwise: Boolean) {
        finishFrameMove()
        val k = turnScale()
        bitmap = turned
        ratio = ratio?.let { 1 / it }
        layoutFrame()
        val x = if (clockwise) -offset.y else offset.y
        val y = if (clockwise) offset.x else -offset.x
        scale *= k
        offset.set(x * k, y * k)
        fit()
        invalidate()
    }

    /** The room the frame may take. */
    private fun room(): RectF {
        val margin = density * if (insetTop == 0f && insetBottom == 0f) 8 else 20
        val side = if (free) density * FREE_SIDE else margin
        return RectF(side, insetTop + margin, width - max(side, insetEnd), height - insetBottom - margin)
    }

    /** The largest frame of these proportions, centred in the room. */
    private fun target(ratio: Float): RectF {
        val room = room()
        val w = minOf(room.width(), room.height() * ratio)
        val h = w / ratio
        return RectF(room.centerX() - w / 2, room.centerY() - h / 2, room.centerX() + w / 2, room.centerY() + h / 2)
    }

    private fun layoutFrame() {
        val image = bitmap ?: return
        if (width == 0) return
        frame.set(target(ratio ?: (image.width.toFloat() / image.height)))
    }

    /**
     * Jumps a running frame move to its end. A finished one is left alone:
     * ending it again would replay its last step, putting the picture back
     * where that move left it.
     */
    private fun finishFrameMove() {
        frameMove?.takeIf { it.isRunning }?.end()
        frameMove = null
    }

    /** The frame eased to [to], [step] keeping the picture in step with it. */
    private fun moveFrame(to: RectF, step: () -> Unit) {
        finishFrameMove()
        val from = RectF(frame)
        frameMove = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = FRAME_MS
            interpolator = DecelerateInterpolator()
            addUpdateListener {
                val t = it.animatedValue as Float
                frame.set(
                    from.left + (to.left - from.left) * t,
                    from.top + (to.top - from.top) * t,
                    from.right + (to.right - from.right) * t,
                    from.bottom + (to.bottom - from.bottom) * t,
                )
                step()
                fit()
                invalidate()
            }
            start()
        }
    }

    /** After the edges let go: the new frame grows back to fill the room, the picture with it. */
    private fun settle() {
        val proportions = frame.width() / frame.height()
        ratio = proportions
        val startWidth = frame.width()
        val startScale = scale
        val start = PointF(offset.x, offset.y)
        moveFrame(target(proportions)) {
            val k = frame.width() / startWidth
            scale = startScale * k
            offset.set(start.x * k, start.y * k)
        }
    }

    private fun edgesAt(x: Float, y: Float): Int {
        val reach = density * 24
        if (x < frame.left - reach || x > frame.right + reach || y < frame.top - reach || y > frame.bottom + reach) return 0
        var found = 0
        if (abs(x - frame.left) < reach) found = found or LEFT else if (abs(x - frame.right) < reach) found = found or RIGHT
        if (abs(y - frame.top) < reach) found = found or TOP else if (abs(y - frame.bottom) < reach) found = found or BOTTOM
        return found
    }

    /** The held edges moved, within the room and as far as the picture reaches; the picture stays put. */
    private fun drag(dx: Float, dy: Float) {
        val room = room()
        val least = density * 80
        val next = RectF(frame)
        if (edges and LEFT != 0) next.left = (next.left + dx).coerceIn(room.left, next.right - least)
        if (edges and RIGHT != 0) next.right = (next.right + dx).coerceIn(next.left + least, room.right)
        if (edges and TOP != 0) next.top = (next.top + dy).coerceIn(room.top, next.bottom - least)
        if (edges and BOTTOM != 0) next.bottom = (next.bottom + dy).coerceIn(next.top + least, room.bottom)
        // Each direction on its own too, so a corner at the picture's edge slides along it.
        val tries = listOf(next, RectF(next.left, frame.top, next.right, frame.bottom), RectF(frame.left, next.top, frame.right, next.bottom))
        val fits = tries.firstOrNull { covered(it) } ?: return
        offset.x += frame.centerX() - fits.centerX()
        offset.y += frame.centerY() - fits.centerY()
        frame.set(fits)
        invalidate()
    }

    /** Whether the picture, as it lies now, fills [rect]. */
    private fun covered(rect: RectF): Boolean {
        val image = bitmap ?: return false
        val inverse = Matrix().also { buildMatrix().invert(it) }
        val corners = floatArrayOf(rect.left, rect.top, rect.right, rect.top, rect.right, rect.bottom, rect.left, rect.bottom)
        inverse.mapPoints(corners)
        val slack = 0.5f
        for (i in corners.indices step 2) {
            if (corners[i] < -slack || corners[i] > image.width + slack) return false
            if (corners[i + 1] < -slack || corners[i + 1] > image.height + slack) return false
        }
        return true
    }

    /** Small enough and the turned frame would reach past the picture's edges. */
    private fun minScale(): Float {
        val image = bitmap ?: return 1f
        val r = Math.toRadians(angle.toDouble())
        val c = abs(cos(r)).toFloat()
        val s = abs(sin(r)).toFloat()
        val needW = frame.width() * c + frame.height() * s
        val needH = frame.width() * s + frame.height() * c
        return max(needW / image.width, needH / image.height)
    }

    /** Keeps the frame covered: scale first, then the offset, in the picture's own axes. */
    private fun fit() {
        val image = bitmap ?: return
        scale = scale.coerceAtLeast(minScale())
        // Each frame corner, in picture pixels; any that falls outside pulls the picture along.
        repeat(2) {
            val inverse = Matrix().also { buildMatrix().invert(it) }
            val corners = floatArrayOf(frame.left, frame.top, frame.right, frame.top, frame.right, frame.bottom, frame.left, frame.bottom)
            inverse.mapPoints(corners)
            var dx = 0f
            var dy = 0f
            for (i in corners.indices step 2) {
                val x = corners[i]
                val y = corners[i + 1]
                if (x < 0) dx = minOf(dx, x) else if (x > image.width) dx = max(dx, x - image.width)
                if (y < 0) dy = minOf(dy, y) else if (y > image.height) dy = max(dy, y - image.height)
            }
            if (dx == 0f && dy == 0f) return
            // A shift of the picture by (dx, dy) of its own pixels, as seen on screen.
            val shift = floatArrayOf(dx * scale, dy * scale)
            Matrix().apply { setRotate(angle) }.mapVectors(shift)
            offset.x += shift[0]
            offset.y += shift[1]
        }
    }

    /** Picture pixels to the screen: centred on the frame plus the offset, turned, scaled. */
    private fun buildMatrix(): Matrix = drawMatrix.apply {
        val image = bitmap ?: return@apply
        reset()
        postTranslate(-image.width / 2f, -image.height / 2f)
        postScale(scale, scale)
        postRotate(angle)
        postTranslate(frame.centerX() + offset.x, frame.centerY() + offset.y)
    }

    /** What the frame holds now, for the render at full size. */
    fun crop(): Crop? {
        bitmap ?: return null
        val inverse = Matrix().also { buildMatrix().invert(it) }
        val center = floatArrayOf(frame.centerX(), frame.centerY())
        inverse.mapPoints(center)
        return Crop(PointF(center[0], center[1]), frame.width() / scale, frame.height() / scale, angle)
    }

    override fun onDraw(canvas: Canvas) {
        val image = bitmap ?: return
        canvas.drawBitmap(image, buildMatrix(), null)

        shade.reset()
        shade.addRect(0f, 0f, width.toFloat(), height.toFloat(), Path.Direction.CW)
        shade.addRect(frame, Path.Direction.CW)
        canvas.drawPath(shade, shadePaint)

        if (showGrid || edges != 0) {
            for (i in 1 until GRID) {
                val x = frame.left + frame.width() * i / GRID
                val y = frame.top + frame.height() * i / GRID
                canvas.drawLine(x, frame.top, x, frame.bottom, gridPaint)
                canvas.drawLine(frame.left, y, frame.right, y, gridPaint)
            }
        }
        canvas.drawRect(frame, framePaint)
        if (free) drawHandles(canvas)
        keepBackGestureOff()
    }

    /**
     * The frame's sides lie where the system's back swipe starts; while they
     * can be dragged, the middle of each side is kept for the frame.
     */
    private fun keepBackGestureOff() {
        val rects = if (!free) emptyList() else {
            val half = (density * 100).toInt()
            val reach = (density * 24).toInt()
            val y = frame.centerY().toInt()
            listOf(
                Rect(0, y - half, frame.left.toInt() + reach, y + half),
                Rect(frame.right.toInt() - reach, y - half, width, y + half),
            )
        }
        if (rects == excluded || android.os.Build.VERSION.SDK_INT < 29) return
        excluded = rects
        systemGestureExclusionRects = rects
    }
    private var excluded = emptyList<Rect>()

    /** Corners to take hold of, just outside the frame. */
    private fun drawHandles(canvas: Canvas) {
        val arm = density * 18
        val out = handlePaint.strokeWidth / 2
        val l = frame.left - out
        val t = frame.top - out
        val r = frame.right + out
        val b = frame.bottom + out
        canvas.drawLines(floatArrayOf(
            l, t, l + arm, t, l, t, l, t + arm,
            r, t, r - arm, t, r, t, r, t + arm,
            r, b, r - arm, b, r, b, r, b - arm,
            l, b, l + arm, b, l, b, l, b - arm,
        ), handlePaint)
    }

    private companion object {
        const val MAX_ZOOM = 8f
        const val GRID = 8
        const val SHADE_RESTING = 190
        const val SHADE_EDITING = 90
        const val FRAME_MS = 260L
        /** Clear of the back swipe at the screen's sides, in dp. */
        const val FREE_SIDE = 56
        const val LEFT = 1
        const val TOP = 2
        const val RIGHT = 4
        const val BOTTOM = 8
    }
}

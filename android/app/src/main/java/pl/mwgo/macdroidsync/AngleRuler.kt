package pl.mwgo.macdroidsync

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * A ruler of degrees under a fixed centre mark. Dragged sideways, the scale
 * slides and [angle] follows in tenths of a degree, from -45 to 45; it holds
 * for a moment at zero, with a tick of the phone, so level is easy to find.
 */
class AngleRuler @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {

    /** The angle, and whether a finger is still on the ruler. */
    var onAngle: ((Float, Boolean) -> Unit)? = null

    var angle = 0f
        private set

    private val density = resources.displayMetrics.density
    /** Pixels the scale slides for one degree. */
    private val perDegree = density * 12
    private var lastX = 0f
    private var held = 0f

    private val tick = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(150, 255, 255, 255)
        strokeWidth = density
    }
    private val major = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        strokeWidth = density * 1.5f
    }
    private val centre = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(0xFF, 0xC1, 0x07)
        strokeWidth = density * 2
    }
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = density * 11
        textAlign = Paint.Align.CENTER
    }
    private val value = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(0xFF, 0xC1, 0x07)
        textSize = density * 15
        textAlign = Paint.Align.CENTER
        isFakeBoldText = true
    }

    fun reset() {
        angle = 0f
        held = 0f
        invalidate()
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                lastX = event.x
                parent?.requestDisallowInterceptTouchEvent(true)
                onAngle?.invoke(angle, true)
            }
            MotionEvent.ACTION_MOVE -> {
                // Sliding the scale left turns the picture clockwise.
                slide((lastX - event.x) / perDegree)
                lastX = event.x
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> onAngle?.invoke(angle, false)
        }
        return true
    }

    private fun slide(degrees: Float) {
        val before = angle
        var next = (angle + degrees).coerceIn(-MAX, MAX)
        // Level holds firmly: a turn that crosses or nears zero stops there, and
        // leaving it again takes a deliberate drag.
        if (before != 0f && ((before < 0) != (next < 0) || abs(next) < MAGNET)) {
            held = 0f
            next = 0f
            performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        } else if (before == 0f || next == 0f) {
            held += degrees
            if (abs(held) < STICK) return
            // Out of zero just past the pull, so the turn goes on smoothly from there.
            next = (Math.signum(held) * (MAGNET + abs(held) - STICK)).coerceIn(-MAX, MAX)
            held = 0f
        }
        angle = (next * 10).roundToInt() / 10f
        invalidate()
        onAngle?.invoke(angle, true)
    }

    override fun onDraw(canvas: Canvas) {
        val mid = width / 2f
        val base = height - density * 16
        canvas.drawText("%.1f°".format(angle), mid, density * 16, value)
        val first = (angle - mid / perDegree).toInt() - 1
        val last = (angle + mid / perDegree).toInt() + 1
        for (degree in first..last) {
            if (degree < -MAX || degree > MAX) continue
            val x = mid + (degree - angle) * perDegree
            val big = degree % 5 == 0
            val length = if (big) density * 16 else density * 9
            canvas.drawLine(x, base - length, x, base, if (big) major else tick)
            if (degree % 15 == 0) canvas.drawText("$degree", x, base + density * 13, label)
        }
        canvas.drawLine(mid, base - density * 24, mid, base + density * 2, centre)
    }

    private companion object {
        const val MAX = 45f
        /** Degrees of drag it takes to leave zero. */
        const val STICK = 2.5f
        /** Nearer zero than this, a turn falls into it. */
        const val MAGNET = 0.4f
    }
}

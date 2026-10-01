package pl.wojas.macdroidsync

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.view.MotionEvent
import android.view.View
import androidx.core.graphics.ColorUtils
import com.google.android.material.color.MaterialColors
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs

/**
 * A sheet to draw on with a finger. The sheet ends at a line with a handle,
 * which can be dragged up or down to make it shorter or taller; below it the
 * screen is dimmed and strokes are cut off. [export] gives the sheet as it
 * will go into the note, and [save] and [load] keep its strokes, so that it
 * can be drawn on again later.
 */
class DrawingView(context: Context) : View(context) {

    /**
     * One stroke: its points as they came, kept to be saved, and the smoothed
     * path drawn through them, which curves through the middle of each step.
     */
    private class Stroke(color: Int, width: Float) {
        val points = mutableListOf<Float>()
        val path = Path()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.DITHER_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            this.color = color
            strokeWidth = width
        }
        private var lastX = 0f
        private var lastY = 0f

        fun start(x: Float, y: Float) {
            points += x
            points += y
            // A dot for a tap: a path of one point draws nothing without a tiny line.
            path.moveTo(x, y)
            path.lineTo(x + 0.1f, y)
            lastX = x
            lastY = y
        }

        fun add(x: Float, y: Float) {
            points += x
            points += y
            path.quadTo(lastX, lastY, (x + lastX) / 2, (y + lastY) / 2)
            lastX = x
            lastY = y
        }

        fun end(x: Float, y: Float) {
            points += x
            points += y
            path.lineTo(x, y)
        }
    }

    private val strokes = mutableListOf<Stroke>()
    private var current: Stroke? = null

    /** A saved drawing waiting for the view to have a width to scale it to. */
    private var pending: String? = null

    private val density = resources.displayMetrics.density
    private fun dp(value: Float) = value * density

    var color = Color.BLACK
    var brush = dp(5f)

    /** Told whenever there is more or less to undo. */
    var onChanged: (() -> Unit)? = null

    /** Height of the sheet, from the top of the view down to its line; 0 until laid out. */
    private var sheet = 0f
    private var resizing = false
    private val minSheet = dp(96f)
    private val grab = dp(28f)

    private val paper = Paint().apply { color = Color.WHITE }
    private val outside = Paint().apply {
        color = ColorUtils.setAlphaComponent(
            MaterialColors.getColor(context, com.google.android.material.R.attr.colorSurfaceVariant, Color.LTGRAY), 0xC0,
        )
    }
    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = MaterialColors.getColor(context, com.google.android.material.R.attr.colorOutline, Color.GRAY)
        strokeWidth = dp(1.5f)
    }
    private val handle = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = line.color }

    val isEmpty get() = strokes.isEmpty()
    val canUndo get() = strokes.isNotEmpty()

    fun clear() {
        strokes.clear()
        current = null
        pending = null
        sheet = if (width > 0) defaultSheet() else 0f
        invalidate()
        onChanged?.invoke()
    }

    private fun defaultSheet() = (height * 0.45f).coerceAtLeast(minSheet)

    fun undo() {
        if (strokes.isEmpty()) return
        strokes.removeAt(strokes.size - 1)
        invalidate()
        onChanged?.invoke()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        sheet = if (sheet == 0f) defaultSheet() else sheet.coerceIn(minSheet, maxSheet())
        pending?.let {
            pending = null
            load(it)
        }
    }

    private fun maxSheet() = (height - dp(12f)).coerceAtLeast(minSheet)

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        canvas.drawRect(0f, 0f, w, sheet, paper)
        canvas.drawRect(0f, sheet, w, height.toFloat(), outside)
        canvas.save()
        canvas.clipRect(0f, 0f, w, sheet)
        for (stroke in strokes) canvas.drawPath(stroke.path, stroke.paint)
        current?.let { canvas.drawPath(it.path, it.paint) }
        canvas.restore()
        canvas.drawLine(0f, sheet, w, sheet, line)
        val half = dp(22f)
        val thick = dp(3f)
        canvas.drawRoundRect(w / 2 - half, sheet - thick, w / 2 + half, sheet + thick, thick, thick, handle)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val x = event.x
        val y = event.y
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                parent?.requestDisallowInterceptTouchEvent(true)
                if (abs(y - sheet) < grab) {
                    resizing = true
                    return true
                }
                if (y > sheet) return false
                current = Stroke(color, brush).apply { start(x, y) }
                invalidate()
            }
            MotionEvent.ACTION_MOVE -> {
                if (resizing) {
                    sheet = y.coerceIn(minSheet, maxSheet())
                    invalidate()
                    return true
                }
                val stroke = current ?: return true
                // Every point in between, so that fast strokes stay smooth.
                for (i in 0 until event.historySize) stroke.add(event.getHistoricalX(i), event.getHistoricalY(i))
                stroke.add(x, y)
                invalidate()
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                resizing = false
                current?.let {
                    it.end(x, y)
                    strokes += it
                    current = null
                    invalidate()
                    onChanged?.invoke()
                }
            }
        }
        return true
    }

    /**
     * The strokes and the sheet as JSON, in pixels of this view together with
     * its width, so that a screen of another width can scale them on [load].
     */
    fun save(): String = JSONObject().apply {
        put("width", width)
        put("sheet", sheet.toDouble())
        put("strokes", JSONArray().apply {
            for (stroke in strokes) put(JSONObject().apply {
                put("color", stroke.paint.color)
                put("size", stroke.paint.strokeWidth.toDouble())
                put("points", JSONArray().apply { stroke.points.forEach { put(it.toDouble()) } })
            })
        })
    }.toString()

    /** Draws a [save]d drawing again, scaled to the width this view has now; once laid out if not yet. */
    fun load(json: String) {
        if (width == 0) {
            pending = json
            return
        }
        val data = runCatching { JSONObject(json) }.getOrNull() ?: return
        val scale = width / data.optDouble("width", width.toDouble()).toFloat().coerceAtLeast(1f)
        strokes.clear()
        val list = data.optJSONArray("strokes") ?: JSONArray()
        for (i in 0 until list.length()) {
            val item = list.getJSONObject(i)
            val p = item.getJSONArray("points")
            if (p.length() < 2) continue
            val stroke = Stroke(item.getInt("color"), item.getDouble("size").toFloat() * scale)
            val n = p.length() / 2
            for (k in 0 until n) {
                val x = p.getDouble(2 * k).toFloat() * scale
                val y = p.getDouble(2 * k + 1).toFloat() * scale
                when (k) {
                    0 -> stroke.start(x, y)
                    n - 1 -> stroke.end(x, y)
                    else -> stroke.add(x, y)
                }
            }
            strokes += stroke
        }
        sheet = (data.optDouble("sheet", defaultSheet().toDouble()).toFloat() * scale).coerceIn(minSheet, maxSheet())
        invalidate()
        onChanged?.invoke()
    }

    /** The sheet with what is drawn on it, cut off at its line, or null when nothing is drawn. */
    fun export(): Bitmap? {
        if (strokes.isEmpty() || width == 0) return null
        val bitmap = Bitmap.createBitmap(width, sheet.toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        for (stroke in strokes) canvas.drawPath(stroke.path, stroke.paint)
        return bitmap
    }
}

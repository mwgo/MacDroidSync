package pl.wojas.macdroidsync

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageButton
import com.google.android.material.color.MaterialColors
import kotlin.math.roundToInt

/**
 * The drawing screen: a [DrawingView] filling [screen], and the buttons the
 * note's toolbar shows while it is open. [onDone] and [onDiscard] are the
 * way out; the colours and brush sizes change what the next stroke looks like.
 */
class DrawingEditor(private val screen: FrameLayout) {

    private val context: Context = screen.context
    private val density = context.resources.displayMetrics.density
    private fun dp(value: Float) = (value * density).roundToInt()

    val canvas = DrawingView(context)

    var onDone: (() -> Unit)? = null
    var onDiscard: (() -> Unit)? = null

    private val ink = MaterialColors.getColor(context, com.google.android.material.R.attr.colorOnSurface, Color.BLACK)
    private val outline = MaterialColors.getColor(context, com.google.android.material.R.attr.colorOutline, Color.GRAY)

    private val undo = button(R.drawable.ic_tool_undo, R.string.draw_undo, tinted = true) { canvas.undo() }
    private val colorButtons = COLORS.map { (color, label) ->
        button(swatch(color), label) { pickColor(color) }.also { it.tag = color }
    }
    private val shapeButtons = SHAPES.map { (shape, icon, label) ->
        button(icon, label, tinted = true) { pickShape(shape) }.also { it.tag = shape }
    }
    private val sizeButtons = SIZES.map { (size, label) ->
        button(dot(size), label) { pickSize(size) }.also { it.tag = size }
    }

    /** In the order they go on the toolbar. */
    val tools: List<View> = listOf(
        button(R.drawable.ic_tool_done, R.string.draw_done, tinted = true) { onDone?.invoke() },
        undo,
        button(R.drawable.ic_tool_delete, R.string.draw_discard, tinted = true) { onDiscard?.invoke() },
    ) + shapeButtons + colorButtons + sizeButtons

    init {
        screen.addView(canvas, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        canvas.onChanged = ::showUndo
        pickColor(COLORS.first().first)
        pickSize(SIZES[1].first)
        pickShape(Shape.PEN)
    }

    /** Starts a new drawing on an empty sheet, or draws on a [save]d one again. */
    fun open(saved: String? = null) {
        canvas.clear()
        saved?.let(canvas::load)
        showUndo()
    }

    private fun showUndo() {
        undo.isEnabled = canvas.canUndo
        undo.alpha = if (canvas.canUndo) 1f else 0.38f
    }

    private fun pickColor(color: Int) {
        canvas.color = color
        for (b in colorButtons) b.isSelected = b.tag == color
    }

    private fun pickShape(shape: Shape) {
        canvas.shape = shape
        for (b in shapeButtons) b.isSelected = b.tag == shape
    }

    private fun pickSize(size: Float) {
        canvas.brush = size * density
        for (b in sizeButtons) b.isSelected = b.tag == size
    }

    private fun button(icon: Int, label: Int, tinted: Boolean, action: () -> Unit) =
        button(context.getDrawable(icon)!!, label, action).apply {
            if (tinted) imageTintList = ColorStateList.valueOf(ink)
        }

    private fun button(image: android.graphics.drawable.Drawable, label: Int, action: () -> Unit) =
        ImageButton(context, null, 0, R.style.NoteTool_Icon).apply {
            setImageDrawable(image)
            contentDescription = context.getString(label)
            tooltipText = contentDescription
            layoutParams = ViewGroup.MarginLayoutParams(dp(44f), dp(44f)).apply {
                marginStart = dp(2f)
                marginEnd = dp(2f)
            }
            setOnClickListener { action() }
        }

    /** A round swatch of the colour with a thin ring, so that white would show too. */
    private fun swatch(color: Int) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
        setStroke(dp(1f), outline)
        setSize(dp(22f), dp(22f))
    }

    /**
     * A dot that grows with the brush, centred in the button. The thin brush
     * would be a speck at its real width, so every dot is drawn larger.
     */
    private fun dot(size: Float): LayerDrawable {
        val box = dp(22f)
        val d = dp(4f + size * 1.4f).coerceAtMost(box)
        val circle = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(ink)
            setSize(d, d)
        }
        return LayerDrawable(arrayOf(circle)).apply {
            val inset = (box - d) / 2
            setLayerInset(0, inset, inset, inset, inset)
            setLayerSize(0, d, d)
        }.also { it.setBounds(0, 0, box, box) }
    }

    private companion object {
        val COLORS = listOf(
            Color.rgb(0x1C, 0x1B, 0x1F) to R.string.draw_black,
            Color.rgb(0xE5, 0x39, 0x35) to R.string.draw_red,
            Color.rgb(0xFB, 0x8C, 0x00) to R.string.draw_orange,
            Color.rgb(0x43, 0xA0, 0x47) to R.string.draw_green,
            Color.rgb(0x1E, 0x88, 0xE5) to R.string.draw_blue,
            Color.rgb(0x8E, 0x24, 0xAA) to R.string.draw_purple,
        )

        val SHAPES = listOf(
            Triple(Shape.PEN, R.drawable.ic_shape_pen, R.string.draw_pen),
            Triple(Shape.LINE, R.drawable.ic_shape_line, R.string.draw_line),
            Triple(Shape.ARROW, R.drawable.ic_shape_arrow, R.string.draw_arrow),
            Triple(Shape.RECTANGLE, R.drawable.ic_shape_rectangle, R.string.draw_rectangle),
            Triple(Shape.OVAL, R.drawable.ic_shape_circle, R.string.draw_circle),
        )

        /** Brush widths in dp. */
        val SIZES = listOf(
            2f to R.string.draw_thin,
            5f to R.string.draw_medium,
            10f to R.string.draw_thick,
        )
    }
}

package pl.wojas.macdroidsync

import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.RectF
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * One picture on the whole screen, over everything else. It grows out of the
 * spot where the picture sits in the note and shrinks back into it on close,
 * while a black backdrop fades in and out behind it. It can be pinched to
 * zoom, and a toolbar at the bottom turns it a quarter at a time; [onRotate]
 * is asked for the turned picture, so it can be kept.
 */
class ImageViewer(private val overlay: FrameLayout, private val window: Window) {

    private val context = overlay.context
    private val density = context.resources.displayMetrics.density
    private val backdrop = View(context).apply { setBackgroundColor(Color.BLACK) }
    private val picture = ZoomImageView(context).apply {
        pivotX = 0f
        pivotY = 0f
    }
    private val tools = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setBackgroundColor(Color.argb(0x99, 0, 0, 0))
        val gap = dp(6)
        setPadding(gap, gap, gap, gap)
    }
    private var bitmap: Bitmap? = null
    private var source: (() -> RectF?)? = null
    private var lightStatusBar = false
    private var turning = false
    private val easing = PathInterpolator(0.2f, 0f, 0f, 1f)

    val isOpen get() = overlay.isVisible

    /** Told when a picture opens, and again once it has shrunk back. */
    var onOpenChanged: ((Boolean) -> Unit)? = null

    /** Asked for the picture turned by the given degrees (90 is clockwise), or null when it cannot be. */
    var onRotate: ((Bitmap, Int) -> Bitmap?)? = null

    /** The picture is to be drawn on again; it is a drawing, as [open] was told. */
    var onEdit: (() -> Unit)? = null

    /** The picture is to go from the note. */
    var onDelete: (() -> Unit)? = null

    private lateinit var editButton: View

    init {
        val full = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        overlay.addView(backdrop, full)
        overlay.addView(picture, FrameLayout.LayoutParams(full))
        overlay.addView(
            tools,
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM),
        )
        tool(R.drawable.ic_tool_close, R.string.image_close) { close() }
        tool(R.drawable.ic_tool_rotate_left, R.string.image_rotate_left) { turn(-90) }
        tool(R.drawable.ic_tool_rotate_right, R.string.image_rotate_right) { turn(90) }
        editButton = tool(R.drawable.ic_tool_edit, R.string.image_edit_drawing) { if (!turning) onEdit?.invoke() }
        tool(R.drawable.ic_tool_delete, R.string.image_delete) { if (!turning) onDelete?.invoke() }
        picture.onSingleTap = ::close
        // Clear of the navigation bar, which the overlay reaches under.
        ViewCompat.setOnApplyWindowInsetsListener(tools) { view, insets ->
            view.updatePadding(bottom = dp(6) + insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom)
            insets
        }
    }

    private fun dp(value: Int) = (value * density).roundToInt()

    private fun tool(icon: Int, label: Int, action: () -> Unit): View {
        val button = ImageButton(context, null, 0, R.style.NoteTool_Icon).apply {
            setImageResource(icon)
            imageTintList = ColorStateList.valueOf(Color.WHITE)
            contentDescription = context.getString(label)
            tooltipText = contentDescription
            setOnClickListener { action() }
        }
        tools.addView(button, LinearLayout.LayoutParams(dp(44), dp(44)).apply { marginEnd = dp(4) })
        return button
    }

    /**
     * Shows [bitmap] growing out of [start], in the overlay's coordinates.
     * [whereNow] tells where the picture is in the note at closing time.
     */
    fun open(bitmap: Bitmap, start: RectF, drawing: Boolean, whereNow: () -> RectF?) {
        this.bitmap = bitmap
        editButton.isVisible = drawing
        source = whereNow
        picture.setImageBitmap(bitmap)
        overlay.isVisible = true
        onOpenChanged?.invoke(true)
        val bars = WindowCompat.getInsetsController(window, overlay)
        lightStatusBar = bars.isAppearanceLightStatusBars
        bars.isAppearanceLightStatusBars = false
        backdrop.alpha = 0f
        tools.alpha = 0f
        // Invisible until laid out, so it never shows at its final size first.
        picture.alpha = 0f
        overlay.post {
            picture.alpha = 1f
            place(start, bitmap)
            backdrop.animate().alpha(1f).setDuration(DURATION).setInterpolator(easing).start()
            tools.animate().alpha(1f).setDuration(DURATION).setInterpolator(easing).start()
            picture.animate().scaleX(1f).scaleY(1f).translationX(0f).translationY(0f)
                .setDuration(DURATION).setInterpolator(easing).start()
        }
    }

    /** Turning the picture makes a drawing a plain picture: its strokes no longer match it. */
    private fun forgetDrawing() {
        editButton.isVisible = false
    }

    /** Shrinks the picture back into the note, then runs [after]. */
    fun close(after: (() -> Unit)? = null) {
        if (!isOpen || turning) return
        picture.resetZoom(animated = false)
        val shown = bitmap
        val target = source?.invoke()
        backdrop.animate().alpha(0f).setDuration(DURATION).setInterpolator(easing).start()
        tools.animate().alpha(0f).setDuration(DURATION / 2).start()
        val animation = if (shown != null && target != null) {
            val (scale, dx, dy) = transform(target, shown)
            picture.animate().scaleX(scale).scaleY(scale).translationX(dx).translationY(dy)
        } else {
            picture.animate().alpha(0f)
        }
        animation.setDuration(DURATION).setInterpolator(easing).withEndAction {
            overlay.isVisible = false
            picture.setImageDrawable(null)
            picture.alpha = 1f
            bitmap = null
            WindowCompat.getInsetsController(window, overlay).isAppearanceLightStatusBars = lightStatusBar
            onOpenChanged?.invoke(false)
            after?.invoke()
        }.start()
    }

    /**
     * Turns the picture on screen about its centre, growing or shrinking it to
     * fit the other way round, then swaps in the turned picture itself.
     */
    private fun turn(degrees: Int) {
        val current = bitmap ?: return
        if (turning) return
        val turned = onRotate?.invoke(current, degrees) ?: return
        forgetDrawing()
        turning = true
        picture.resetZoom(animated = false)
        val before = fitted(current)
        val after = fitted(turned)
        picture.pivotX = picture.width / 2f
        picture.pivotY = picture.height / 2f
        val scale = after.width() / before.height()
        picture.animate().rotationBy(degrees.toFloat()).scaleX(scale).scaleY(scale)
            .setDuration(TURN_DURATION).setInterpolator(easing).withEndAction {
                bitmap = turned
                picture.setImageBitmap(turned)
                picture.rotation = 0f
                picture.scaleX = 1f
                picture.scaleY = 1f
                picture.pivotX = 0f
                picture.pivotY = 0f
                turning = false
            }.start()
    }

    private fun place(rect: RectF, bitmap: Bitmap) {
        val (scale, dx, dy) = transform(rect, bitmap)
        picture.scaleX = scale
        picture.scaleY = scale
        picture.translationX = dx
        picture.translationY = dy
    }

    /** Scale and offset that put the picture, fitted to the whole screen, over [rect]. */
    private fun transform(rect: RectF, bitmap: Bitmap): Triple<Float, Float, Float> {
        val fitted = fitted(bitmap)
        val scale = rect.width() / fitted.width()
        return Triple(scale, rect.left - fitted.left * scale, rect.centerY() - fitted.centerY() * scale)
    }

    /** Where the picture is drawn when fitted to the whole screen. */
    private fun fitted(bitmap: Bitmap): RectF {
        val w = overlay.width.toFloat()
        val h = overlay.height.toFloat()
        val scale = min(w / bitmap.width, h / bitmap.height)
        val shownWidth = bitmap.width * scale
        val shownHeight = bitmap.height * scale
        return RectF((w - shownWidth) / 2, (h - shownHeight) / 2, (w + shownWidth) / 2, (h + shownHeight) / 2)
    }

    private companion object {
        const val DURATION = 320L
        const val TURN_DURATION = 260L
    }
}

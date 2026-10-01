package pl.wojas.macdroidsync

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.os.Build
import android.text.TextUtils
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import android.view.VelocityTracker
import android.view.ViewConfiguration
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.ExtractedText
import android.view.inputmethod.ExtractedTextRequest
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputConnectionWrapper
import android.view.inputmethod.InputMethodManager
import android.view.inputmethod.SurroundingText
import androidx.annotation.RequiresApi
import android.widget.OverScroller
import androidx.appcompat.widget.AppCompatEditText
import kotlin.math.abs

/**
 * The text field of the notes editor. It keeps the caret off the invisible
 * [MARK] that starts a line, and hands taps to [onTap] first, so a tap on a
 * checkbox, a heading arrow or a table acts on it instead of moving the caret.
 * A sideways drag over a code block shown unwrapped scrolls that block, and
 * while the caret is hidden a long press lifts a paragraph or a section to be
 * dragged elsewhere; with the caret shown it selects text as usual.
 */
class MarkdownEditText @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) :
    AppCompatEditText(context, attrs) {

    var onTap: ((x: Float, y: Float) -> Boolean)? = null
    var onWidthChanged: (() -> Unit)? = null
    var onSelection: ((start: Int, end: Int) -> Unit)? = null
    var codeScrollAt: ((x: Float, y: Float) -> CodeScroll?)? = null
    var onCodeScrolled: ((CodeScroll) -> Unit)? = null
    var onMoveStart: ((x: Float, y: Float) -> Boolean)? = null
    var onMoveTo: ((y: Float) -> Unit)? = null
    var onMoveEnd: ((commit: Boolean) -> Unit)? = null
    var onSelectLifted: (() -> Unit)? = null

    private var moving = false
    private var moved = false
    private var moveViewportY = 0f
    private var moveVisual: FloatArray? = null
    private val movePaint = Paint()
    private val indicatorPaint = Paint()
    private val density = resources.displayMetrics.density

    /** Scrolls the note while the finger holds a lifted paragraph near its top or bottom edge. */
    private val autoScroll = object : Runnable {
        override fun run() {
            if (!moving) return
            val scroller = parent as? View ?: return
            val edge = 64 * density
            val step = 24 * density
            val dy = when {
                moveViewportY < edge -> -(edge - moveViewportY) / edge * step
                moveViewportY > scroller.height - edge -> (moveViewportY - scroller.height + edge) / edge * step
                else -> 0f
            }
            if (dy != 0f) {
                scroller.scrollBy(0, dy.toInt())
                onMoveTo?.invoke(moveViewportY + scroller.scrollY - top)
            }
            postOnAnimation(this)
        }
    }

    private var codeScroll: CodeScroll? = null
    private var dragging = false
    private var dragX = 0f
    private var dragOffset = 0
    private var velocity: VelocityTracker? = null
    private val scroller = OverScroller(context)
    private val flingStep = object : Runnable {
        override fun run() {
            val scroll = codeScroll ?: return
            if (!scroller.computeScrollOffset()) return
            scroll.x = scroller.currX
            onCodeScrolled?.invoke(scroll)
            postOnAnimation(this)
        }
    }

    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f
    private var downTime = 0L

    init {
        setOnLongClickListener { startMove() }
    }

    fun setMoveColors(highlight: Int, indicator: Int) {
        movePaint.color = highlight
        indicatorPaint.color = indicator
    }

    /** The lifted text, from [top] to [bottom], and the line where it would land, in view coordinates. */
    fun showMove(top: Float, bottom: Float, indicator: Float) {
        moveVisual = floatArrayOf(top, bottom, indicator)
        invalidate()
    }

    fun hideMove() {
        moveVisual = null
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val visual = moveVisual
        if (visual != null) canvas.drawRect(0f, visual[0], width.toFloat(), visual[1], movePaint)
        super.onDraw(canvas)
        if (visual != null) {
            val half = 1.5f * density
            canvas.drawRect(totalPaddingLeft.toFloat(), visual[2] - half, (width - totalPaddingRight).toFloat(), visual[2] + half, indicatorPaint)
        }
    }

    /** Ends the gesture for the field; without it the lifted finger would place the caret and start editing. */
    private fun cancelTouch(event: MotionEvent) {
        val cancel = MotionEvent.obtain(event).apply { action = MotionEvent.ACTION_CANCEL }
        super.onTouchEvent(cancel)
        cancel.recycle()
    }

    /** Only while the caret is hidden; with it shown, a long press selects text as usual. */
    private fun startMove(): Boolean {
        if (hasFocus() || onMoveStart?.invoke(downX, downY) != true) return false
        moving = true
        moved = false
        parent?.requestDisallowInterceptTouchEvent(true)
        moveViewportY = viewportY(downY)
        postOnAnimation(autoScroll)
        return true
    }

    private fun viewportY(y: Float) = y + top - ((parent as? View)?.scrollY ?: 0)

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (moving) {
            when (event.actionMasked) {
                MotionEvent.ACTION_MOVE -> {
                    if (abs(event.x - downX) > touchSlop || abs(event.y - downY) > touchSlop) moved = true
                    moveViewportY = viewportY(event.y)
                    onMoveTo?.invoke(event.y)
                }
                MotionEvent.ACTION_UP -> if (!moved) {
                    // Held without moving: start editing with what was lifted
                    // selected, but leave the keyboard closed until the text is
                    // touched again. The field's own long press is what brings
                    // up the handles and the menu; the selection then grows
                    // from its word to the paragraph or section.
                    moving = false
                    onMoveEnd?.invoke(false)
                    showSoftInputOnFocus = false
                    requestFocus()
                    performLongClick()
                    val handled = super.onTouchEvent(event)
                    post { onSelectLifted?.invoke() }
                    return handled
                } else {
                    moving = false
                    onMoveEnd?.invoke(true)
                    cancelTouch(event)
                }
                MotionEvent.ACTION_CANCEL -> {
                    moving = false
                    onMoveEnd?.invoke(false)
                    cancelTouch(event)
                }
            }
            return true
        }
        if (dragCode(event)) return true
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                showSoftInputOnFocus = true
                downX = event.x
                downY = event.y
                downTime = event.eventTime
            }
            MotionEvent.ACTION_UP -> if (isTap(event) && onTap?.invoke(event.x, event.y) == true) {
                // The field saw the finger go down; cancelling tells it the gesture is over.
                val cancel = MotionEvent.obtain(event).apply { action = MotionEvent.ACTION_CANCEL }
                super.onTouchEvent(cancel)
                cancel.recycle()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    /**
     * Follows a finger that went down on an unwrapped code block. Once it moves
     * further sideways than up or down it takes the gesture: the text field and
     * the scroll view around it let go, and the block scrolls, then flings.
     */
    private fun dragCode(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                scroller.forceFinished(true)
                dragging = false
                codeScroll = codeScrollAt?.invoke(event.x, event.y)
                velocity?.recycle()
                velocity = codeScroll?.let { VelocityTracker.obtain() }
                velocity?.addMovement(event)
            }
            MotionEvent.ACTION_MOVE -> {
                val scroll = codeScroll ?: return false
                velocity?.addMovement(event)
                if (!dragging) {
                    val dx = abs(event.x - downX)
                    if (dx <= touchSlop || dx <= abs(event.y - downY) || scroll.max == 0) return false
                    dragging = true
                    dragX = event.x
                    dragOffset = scroll.x
                    parent?.requestDisallowInterceptTouchEvent(true)
                    val cancel = MotionEvent.obtain(event).apply { action = MotionEvent.ACTION_CANCEL }
                    super.onTouchEvent(cancel)
                    cancel.recycle()
                }
                scroll.x = (dragOffset - (event.x - dragX)).toInt().coerceIn(0, scroll.max)
                onCodeScrolled?.invoke(scroll)
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                val scroll = codeScroll
                val tracker = velocity
                velocity = null
                if (!dragging || scroll == null) {
                    tracker?.recycle()
                    return false
                }
                dragging = false
                tracker?.addMovement(event)
                tracker?.computeCurrentVelocity(1000)
                val vx = tracker?.xVelocity?.toInt() ?: 0
                tracker?.recycle()
                if (event.actionMasked == MotionEvent.ACTION_UP && vx != 0) {
                    scroller.fling(scroll.x, 0, -vx, 0, 0, scroll.max, 0, 0)
                    postOnAnimation(flingStep)
                }
                return true
            }
        }
        return false
    }

    private fun isTap(event: MotionEvent) =
        abs(event.x - downX) < touchSlop &&
            abs(event.y - downY) < touchSlop &&
            event.eventTime - downTime < ViewConfiguration.getLongPressTimeout()

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w != oldw) onWidthChanged?.invoke()
    }

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
        super.onSelectionChanged(selStart, selEnd)
        val t = text ?: return
        val start = skipMarker(t, selStart)
        val end = skipMarker(t, selEnd)
        if (start != selStart || end != selEnd) return setSelection(start, end)
        onSelection?.invoke(start, end)
        // What the keyboard is told of later edits comes with the marks; it reads the text anew
        // once the caret reaches the start of a marked line, so that the line starts a sentence.
        val atMark = start == end && start > 0 && t[start - 1] == MARK
        if (atMark && !afterMark && hasFocus()) post {
            context.getSystemService(InputMethodManager::class.java)?.restartInput(this)
        }
        afterMark = atMark
    }

    private var afterMark = false

    /**
     * The keyboard capitalises a sentence's first letter by what comes before
     * the caret; the [MARK] starting a title or a list item is not something
     * written, so the caret right after it is at the start of the line.
     */
    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        val connection = super.onCreateInputConnection(outAttrs) ?: return null
        outAttrs.initialCapsMode = capsMode(outAttrs.inputType)
        return object : InputConnectionWrapper(connection, true) {
            override fun getCursorCapsMode(reqModes: Int) = capsMode(reqModes)

            // Keyboards that judge by the text itself see a line break in its place, as long as it.
            override fun getTextBeforeCursor(n: Int, flags: Int) = unmarked(super.getTextBeforeCursor(n, flags))

            override fun getExtractedText(request: ExtractedTextRequest?, flags: Int): ExtractedText? =
                super.getExtractedText(request, flags)?.apply { text = unmarked(text) }

            @RequiresApi(Build.VERSION_CODES.S)
            override fun getSurroundingText(beforeLength: Int, afterLength: Int, flags: Int): SurroundingText? {
                val around = super.getSurroundingText(beforeLength, afterLength, flags) ?: return null
                if (around.text.none { it == MARK }) return around
                return SurroundingText(unmarked(around.text)!!, around.selectionStart, around.selectionEnd, around.offset)
            }
        }
    }

    private fun unmarked(text: CharSequence?): CharSequence? =
        if (text == null || text.none { it == MARK }) text else text.toString().replace(MARK, '\n')

    private fun capsMode(reqModes: Int): Int {
        val t = text ?: return 0
        var at = selectionStart
        if (at < 0) return 0
        while (at > 0 && t[at - 1] == MARK) at--
        return TextUtils.getCapsMode(t, at, reqModes)
    }

    private fun skipMarker(t: CharSequence, at: Int) =
        if (at in t.indices && t[at] == MARK && (at == 0 || t[at - 1] == '\n')) at + 1 else at
}

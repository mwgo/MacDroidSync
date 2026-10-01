package pl.wojas.macdroidsync

import android.content.Context
import android.util.AttributeSet
import android.view.MotionEvent
import android.widget.TableLayout

/**
 * The grid of the table editor. It lets [onIntercept] take a gesture away from
 * the cell it started on, and hands the rest of that gesture to [onDrag].
 */
class TableGrid @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : TableLayout(context, attrs) {

    var onIntercept: ((MotionEvent) -> Boolean)? = null
    var onDrag: ((MotionEvent) -> Unit)? = null

    override fun onInterceptTouchEvent(event: MotionEvent) = onIntercept?.invoke(event) == true

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val drag = onDrag ?: return super.onTouchEvent(event)
        drag(event)
        return true
    }
}

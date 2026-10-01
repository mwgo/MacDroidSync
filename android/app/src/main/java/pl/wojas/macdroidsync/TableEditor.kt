package pl.wojas.macdroidsync

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.text.InputFilter
import android.text.InputType
import android.view.Gravity
import android.view.MotionEvent
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.TableRow
import com.google.android.material.color.MaterialColors
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * One table edited on the whole screen, as a grid of bordered fields like an
 * HTML table. Rows and columns are added next to the cell that has the focus.
 * Holding a cell and dragging to the next one sideways selects its whole row,
 * up or down its whole column; a selection can then be moved or deleted. The
 * buttons for all of that live in the note's toolbar.
 */
class TableEditor(private val grid: TableGrid) {

    enum class Axis { ROW, COLUMN }

    data class Selection(val axis: Axis, val index: Int)

    /** The whole row or column selected, if any. */
    var selection: Selection? = null
        private set

    /** Called whenever [selection] changes, or what it may do, so the toolbar can follow. */
    var onSelectionChanged: (() -> Unit)? = null

    private val context: Context = grid.context
    private val density = context.resources.displayMetrics.density
    private val lineColor = MaterialColors.getColor(context, com.google.android.material.R.attr.colorOutline, Color.GRAY)
    private val cellColor = MaterialColors.getColor(context, com.google.android.material.R.attr.colorSurface, Color.WHITE)
    private val focusColor = MaterialColors.getColor(context, androidx.appcompat.R.attr.colorPrimary, Color.BLUE)
    private val selectedColor = MaterialColors.getColor(context, com.google.android.material.R.attr.colorPrimaryContainer, Color.LTGRAY)

    private var rows = mutableListOf<MutableList<String>>()
    private val fields = mutableListOf<List<EditText>>()
    private var row = 0
    private var column = 0

    /** The cell a long press armed for selecting its row or column, until the finger lifts. */
    private var armed: Pair<Int, Int>? = null
    private var dragging = false

    // A pipe would end the cell early once the table is written as Markdown,
    // and a Markdown row has no room for a line break.
    private val cellText = InputFilter { source, _, _, _, _, _ ->
        if (source.any { it == '|' || it == '\n' }) source.toString().replace("|", "").replace('\n', ' ') else null
    }

    init {
        // The grid's own colour shows through one pixel wide gaps between the
        // cells, which draws the borders the way an HTML table collapses them.
        grid.setBackgroundColor(lineColor)
        val line = dp(1)
        grid.setPadding(line, line, 0, 0)
        grid.onIntercept = ::intercept
        grid.onDrag = ::drag
    }

    private fun dp(value: Int) = (value * density).roundToInt()

    val rowCount get() = rows.size
    val columnCount get() = rows.first().size

    fun open(table: MdTable) {
        val width = table.columns.coerceAtLeast(1)
        rows = table.rows.map { r -> MutableList(width) { r.getOrElse(it) { "" } } }.toMutableList()
        if (rows.isEmpty()) rows += MutableList(width) { "" }
        row = 0
        column = 0
        selection = null
        rebuild()
        focus(showKeyboard = true)
        onSelectionChanged?.invoke()
    }

    fun result(): MdTable {
        collect()
        return MdTable(rows.map { it.toList() })
    }

    // region Toolbar

    /** Adds a row below the selected row, or below the cell with the focus. */
    fun addRow() = change {
        val at = selection?.takeIf { it.axis == Axis.ROW }?.index ?: row
        rows.add(at + 1, MutableList(columnCount) { "" })
        row = at + 1
        selection = null
        true
    }

    /** Adds a column right of the selected column, or right of the cell with the focus. */
    fun addColumn() = change {
        val at = selection?.takeIf { it.axis == Axis.COLUMN }?.index ?: column
        rows.forEach { it.add(at + 1, "") }
        column = at + 1
        selection = null
        true
    }

    /** Moves the selected row or column one place back (up or left) or forward (down or right). */
    fun moveSelection(forward: Boolean) = change {
        val sel = selection ?: return@change false
        val to = sel.index + if (forward) 1 else -1
        when (sel.axis) {
            Axis.ROW -> {
                if (to !in rows.indices) return@change false
                rows.add(to, rows.removeAt(sel.index))
            }
            Axis.COLUMN -> {
                if (to !in 0 until columnCount) return@change false
                rows.forEach { it.add(to, it.removeAt(sel.index)) }
            }
        }
        selection = sel.copy(index = to)
        false
    }

    /** Deletes the selected row or column; the last one left stays. */
    fun deleteSelection() = change {
        val sel = selection ?: return@change false
        when (sel.axis) {
            Axis.ROW -> if (rows.size > 1) rows.removeAt(sel.index) else return@change false
            Axis.COLUMN -> if (columnCount > 1) rows.forEach { it.removeAt(sel.index) } else return@change false
        }
        selection = null
        row = min(row, rows.size - 1)
        column = min(column, columnCount - 1)
        false
    }

    /** Rebuilds the grid after [block], which says whether the focused cell should get the focus back. */
    private inline fun change(block: () -> Boolean) {
        collect()
        val refocus = block()
        rebuild()
        if (refocus) focus(showKeyboard = false)
        onSelectionChanged?.invoke()
    }

    // endregion

    // region Selecting a row or column by dragging

    private fun intercept(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                armed = null
                dragging = false
            }
            MotionEvent.ACTION_MOVE -> {
                val from = armed ?: return false
                val over = cellAt(event.x, event.y) ?: return false
                if (over != from) {
                    dragging = true
                    select(from, over)
                    return true
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> armed = null
        }
        return false
    }

    private fun drag(event: MotionEvent) {
        val from = armed ?: return
        when (event.actionMasked) {
            MotionEvent.ACTION_MOVE -> cellAt(event.x, event.y)?.let { if (it != from) select(from, it) }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                armed = null
                dragging = false
            }
        }
    }

    /** Along the row when the finger went sideways, down the column when it went up or down. */
    private fun select(from: Pair<Int, Int>, to: Pair<Int, Int>) {
        val (r, c) = from
        val sideways = to.first == r || (to.second != c && abs(to.second - c) >= abs(to.first - r))
        val next = if (sideways) Selection(Axis.ROW, r) else Selection(Axis.COLUMN, c)
        if (next == selection) return
        if (selection == null) {
            // Selecting whole rows and columns is not typing: the caret and the keyboard go.
            grid.findFocus()?.clearFocus()
            context.getSystemService(InputMethodManager::class.java)?.hideSoftInputFromWindow(grid.windowToken, 0)
        }
        selection = next
        showSelection()
        onSelectionChanged?.invoke()
    }

    private fun cellAt(x: Float, y: Float): Pair<Int, Int>? {
        for (r in 0 until grid.childCount) {
            val tableRow = grid.getChildAt(r) as? TableRow ?: continue
            if (y < tableRow.top || y >= tableRow.bottom) continue
            for (c in 0 until tableRow.childCount) {
                val cell = tableRow.getChildAt(c)
                if (x >= tableRow.left + cell.left && x < tableRow.left + cell.right) return r to c
            }
        }
        return null
    }

    private fun showSelection() {
        val sel = selection
        fields.forEachIndexed { r, cells ->
            cells.forEachIndexed { c, field ->
                field.isActivated = sel != null && (if (sel.axis == Axis.ROW) r else c) == sel.index
            }
        }
    }

    // endregion

    private fun collect() {
        fields.forEachIndexed { r, cells -> cells.forEachIndexed { c, field -> rows[r][c] = field.text.toString().trim() } }
    }

    private fun focus(showKeyboard: Boolean) {
        val field = fields.getOrNull(row)?.getOrNull(column) ?: return
        field.requestFocus()
        field.setSelection(field.length())
        if (showKeyboard) field.post { context.getSystemService(InputMethodManager::class.java)?.showSoftInput(field, 0) }
    }

    private fun rebuild() {
        grid.removeAllViews()
        fields.clear()
        rows.forEachIndexed { r, cells ->
            val tableRow = TableRow(context)
            fields += cells.mapIndexed { c, value -> cell(r, c, value).also { tableRow.addView(it, cellParams()) } }
            grid.addView(tableRow)
        }
        showSelection()
    }

    private fun cellParams() = TableRow.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT).apply {
        setMargins(0, 0, dp(1), dp(1))
    }

    private fun cell(r: Int, c: Int, value: String) = EditText(context).apply {
        setText(value)
        // Multi-line so that long text wraps inside its cell; the filter keeps line breaks out.
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        filters = arrayOf(cellText)
        gravity = Gravity.TOP or Gravity.START
        minWidth = dp(96)
        maxWidth = dp(260)
        setPadding(dp(10), dp(8), dp(10), dp(8))
        background = cellBackground()
        setOnFocusChangeListener { _, focused ->
            if (!focused) return@setOnFocusChangeListener
            row = r
            column = c
            // Going back to a cell to type ends the selection.
            if (selection != null && !dragging) {
                selection = null
                showSelection()
                onSelectionChanged?.invoke()
            }
        }
        // A long press arms the drag that selects the row or the column. Taking
        // it here also keeps the field from starting a text selection of its own.
        setOnLongClickListener {
            armed = r to c
            grid.parent?.requestDisallowInterceptTouchEvent(true)
            true
        }
    }

    /** Plain while idle, tinted while its row or column is selected, framed in the accent colour while it has the focus. */
    private fun cellBackground() = StateListDrawable().apply {
        addState(intArrayOf(android.R.attr.state_activated), GradientDrawable().apply { setColor(selectedColor) })
        addState(
            intArrayOf(android.R.attr.state_focused),
            GradientDrawable().apply {
                setColor(cellColor)
                setStroke(dp(2), focusColor)
            },
        )
        addState(intArrayOf(), GradientDrawable().apply { setColor(cellColor) })
    }
}

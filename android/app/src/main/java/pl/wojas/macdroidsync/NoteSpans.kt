package pl.wojas.macdroidsync

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.text.Layout
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextUtils
import android.text.style.BackgroundColorSpan
import android.text.TextPaint
import android.text.style.CharacterStyle
import android.text.style.LeadingMarginSpan
import android.text.style.LineHeightSpan
import android.text.style.LineBackgroundSpan
import android.text.style.MetricAffectingSpan
import android.text.style.ReplacementSpan
import android.text.style.UpdateLayout
import androidx.core.content.ContextCompat
import androidx.core.graphics.ColorUtils
import androidx.core.graphics.withClip
import androidx.core.graphics.withTranslation
import com.google.android.material.color.MaterialColors
import java.util.Locale
import kotlin.math.min
import kotlin.math.roundToInt

/** Invisible first character of every line that is not a plain paragraph; its [MarkerSpan] says what the line is. */
const val MARK = '⁣'

/** The one character a table or a picture takes up, carrying its [ObjectSpan]. */
const val TABLE_CHAR = '￼'

/** Colours and sizes the note spans draw with, resolved once from the screen's theme. */
class NoteStyle(context: Context) {
    private val density = context.resources.displayMetrics.density
    fun dp(value: Float) = value * density

    val gutter = dp(24f).roundToInt()
    val indent = dp(28f).roundToInt()
    val quoteIndent = dp(20f).roundToInt()
    val cellPadding = dp(8f).roundToInt()
    val tableGap = dp(8f).roundToInt()
    val headingAfter = dp(6f).roundToInt()

    /** The room above a heading, by its rank under the title. */
    fun headingBefore(rank: Int) = dp(if (rank == 1) 22f else if (rank == 2) 18f else 16f).roundToInt()

    /** Below the title: from it to its line of when and where, and from that to the rule. */
    val infoGap = dp(6f)
    val ruleGap = dp(12f)
    /** All the room the title leaves below it, down to the text. */
    val titleSpace = dp(46f).roundToInt()

    val primary = MaterialColors.getColor(context, androidx.appcompat.R.attr.colorPrimary, Color.BLUE)
    val onPrimary = MaterialColors.getColor(context, com.google.android.material.R.attr.colorOnPrimary, Color.WHITE)
    val dimmed = MaterialColors.getColor(context, com.google.android.material.R.attr.colorOnSurfaceVariant, Color.GRAY)
    val outline = MaterialColors.getColor(context, com.google.android.material.R.attr.colorOutlineVariant, Color.LTGRAY)
    val surface = MaterialColors.getColor(context, com.google.android.material.R.attr.colorSurfaceVariant, Color.LTGRAY)
    val background = MaterialColors.getColor(context, android.R.attr.colorBackground, Color.WHITE)

    /** Notes MD's amber, as on the Mac: sections, the folder, ticked boxes. */
    val accent = ContextCompat.getColor(context, R.color.note_group_icon)
    val muted = ContextCompat.getColor(context, R.color.note_muted)
    val chevron = ContextCompat.getColor(context, R.color.note_chevron)
    val rule = ContextCompat.getColor(context, R.color.note_rule)
    val quoteBar = ContextCompat.getColor(context, R.color.note_quote_bar)
    val codeBackground = ContextCompat.getColor(context, R.color.note_code_background)
    val codeText = ContextCompat.getColor(context, R.color.note_code_text)
    val box = ContextCompat.getColor(context, R.color.note_box)
    val tick = ContextCompat.getColor(context, R.color.note_tick)
    val folderIcon: Drawable = ContextCompat.getDrawable(context, R.drawable.ic_group_folder)!!.mutate().apply { setTint(accent) }

    /** When the note was edited and its folder, shown under the title. */
    var info: Pair<String, String>? = null
}

/**
 * A heading's rank under the title, which is `#`: 1 for a section (`#` or
 * `##`), 2 for `###`, 3 for the rest, drawn in small grey capitals.
 */
fun headingRank(level: Int) = maxOf(1, minOf(level, 4) - 1)

fun headingScale(level: Int) = when (headingRank(level)) {
    1 -> 1.45f
    2 -> 1.2f
    else -> 0.87f
}

const val TITLE_SCALE = 2f

/**
 * What a line is, attached to its [MARK]. Deleting the mark with a backspace
 * deletes the span with it, which is how a line goes back to a paragraph.
 * [hidden] holds the folded section while a heading is collapsed.
 */
class MarkerSpan(var block: Block) : ReplacementSpan() {
    var number = 0
    var hidden: Spanned? = null
    var line: LineSpan? = null

    /** The block its line was last laid out for, so a change of it is noticed. */
    var drawn: Block? = null

    /** For a code line: the sideways scroll its block shares, and the span that shows it unwrapped. */
    var codeScroll: CodeScroll? = null
    var codeView: CodeViewSpan? = null

    override fun getSize(paint: Paint, text: CharSequence?, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
        // Without metrics of its own a line holding only the mark would collapse to nothing.
        fm?.let { paint.getFontMetricsInt(it) }
        return 0
    }

    override fun draw(canvas: Canvas, text: CharSequence?, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) = Unit
}

/** The spans that render a marked line, rebuilt by the editor whenever the lines move. */
sealed interface LineSpan

/**
 * A heading, with room above it and a little below: amber for a section,
 * black below it, small grey capitals lower still. The note's title, the one
 * at the very start, is larger and black, with none above it and below it a
 * line of when and where and a rule, as Notes MD shows a note on the Mac.
 */
class HeadingLineSpan(private val marker: MarkerSpan, private val style: NoteStyle) :
    MetricAffectingSpan(), LineHeightSpan, LineBackgroundSpan, LineSpan {

    /** Set by the editor: whether this is the first line, the title. */
    var title = false

    /** The ascent the first line was given, room above included. */
    private var raised = Int.MIN_VALUE

    override fun updateMeasureState(tp: TextPaint) = apply(tp)
    override fun updateDrawState(tp: TextPaint) {
        apply(tp)
        if (title) return
        when (headingRank(marker.block.level)) {
            1 -> tp.color = style.accent
            2 -> Unit
            else -> tp.color = style.muted
        }
    }

    override fun chooseHeight(text: CharSequence, start: Int, end: Int, spanstartv: Int, lineHeight: Int, fm: Paint.FontMetricsInt) {
        if (text !is Spanned) return
        val spanStart = text.getSpanStart(this)
        // Right under the title, the rule there already makes room.
        val underTitle = spanStart == TextUtils.indexOf(text, '\n') + 1
        val before = if (title || underTitle) 0 else style.headingBefore(headingRank(marker.block.level))
        if (start == spanStart) {
            fm.ascent -= before
            fm.top -= before
            raised = fm.ascent
        } else if (before > 0 && fm.ascent == raised) {
            // The lines after the first are handed the first one's metrics, room above included.
            fm.ascent += before
            fm.top += before
        }
        if (end < text.getSpanEnd(this)) return
        val after = if (title) style.titleSpace else style.headingAfter
        fm.descent += after
        fm.bottom += after
    }

    private fun apply(tp: TextPaint) {
        tp.textSize *= if (title) TITLE_SCALE else headingScale(marker.block.level)
        tp.typeface = Typeface.create(tp.typeface, Typeface.BOLD)
        if (!title && headingRank(marker.block.level) >= 3) {
            tp.fontFeatureSettings = "smcp, c2sc"
            tp.letterSpacing = 0.06f
        }
    }

    private val infoPaint = TextPaint(Paint.ANTI_ALIAS_FLAG)

    /** Under the title's last line: the date and the folder, then the rule. */
    override fun drawBackground(
        canvas: Canvas, paint: Paint, left: Int, right: Int, top: Int, baseline: Int, bottom: Int,
        text: CharSequence, start: Int, end: Int, lineNumber: Int,
    ) {
        if (!title || text !is Spanned || end < text.getSpanEnd(this)) return
        val x0 = (left + style.gutter).toFloat()
        val infoTop = baseline + paint.textSize * TITLE_SCALE * 0.27f + style.infoGap
        infoPaint.set(paint)
        infoPaint.textSize = paint.textSize * 0.8f
        infoPaint.typeface = Typeface.DEFAULT
        infoPaint.letterSpacing = 0f
        infoPaint.fontFeatureSettings = null
        val lineHeight = infoPaint.descent() - infoPaint.ascent()
        val infoBaseline = infoTop - infoPaint.ascent()
        style.info?.let { (date, folder) ->
            infoPaint.color = style.muted
            val dated = "$date  ·  "
            canvas.drawText(dated, x0, infoBaseline, infoPaint)
            var x = x0 + infoPaint.measureText(dated)
            if (folder.isNotEmpty()) {
                val size = infoPaint.textSize.roundToInt()
                val iconTop = (infoTop + (lineHeight - size) / 2).roundToInt()
                style.folderIcon.setBounds(x.roundToInt(), iconTop, x.roundToInt() + size, iconTop + size)
                style.folderIcon.draw(canvas)
                x += size + style.dp(4f)
                infoPaint.color = style.accent
                infoPaint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                canvas.drawText(folder, x, infoBaseline, infoPaint)
            }
        }
        val ruleTop = infoTop + lineHeight + style.ruleGap
        infoPaint.color = style.rule
        infoPaint.style = Paint.Style.FILL
        canvas.drawRect(x0, ruleTop, right.toFloat(), ruleTop + maxOf(1f, style.dp(1f)), infoPaint)
    }
}

/**
 * A line of a fenced code block: monospace, inset a little, over a background
 * that runs the full width, so the lines of one block form a single panel.
 */
class CodeLineSpan(private val style: NoteStyle) : MetricAffectingSpan(), LeadingMarginSpan, LineBackgroundSpan, LineSpan {
    override fun updateMeasureState(tp: TextPaint) = monospace(tp)

    override fun updateDrawState(tp: TextPaint) = monospace(tp)

    override fun getLeadingMargin(first: Boolean) = style.cellPadding

    override fun drawLeadingMargin(
        c: Canvas, p: Paint, x: Int, dir: Int, top: Int, baseline: Int, bottom: Int,
        text: CharSequence, start: Int, end: Int, first: Boolean, layout: Layout?,
    ) = Unit

    override fun drawBackground(
        canvas: Canvas, paint: Paint, left: Int, right: Int, top: Int, baseline: Int, bottom: Int,
        text: CharSequence, start: Int, end: Int, lineNumber: Int,
    ) {
        val color = paint.color
        paint.color = style.surface
        canvas.drawRect((left + style.gutter).toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat(), paint)
        paint.color = color
    }
}

/** Turns [tp] into the paint code is drawn and measured with. */
fun monospace(tp: TextPaint) {
    tp.typeface = Typeface.MONOSPACE
    tp.textSize *= 0.9f
}

/** How far a code block is scrolled sideways, shared by all of its lines. */
class CodeScroll {
    var x = 0
    var max = 0
}

/**
 * Shows a code line unwrapped while the caret is outside its block: the line
 * takes exactly the width there is and draws its text shifted by the block's
 * [scroll], with a fade at an edge that has more text beyond it. The text stays
 * in the note untouched; the editor removes this span while the block is edited.
 */
class CodeViewSpan(private val style: NoteStyle, private val width: () -> Int) : ReplacementSpan() {
    var scroll = CodeScroll()
    private val fade = Paint()
    private val fadeWidth = style.dp(16f)

    override fun getSize(paint: Paint, text: CharSequence?, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
        fm?.let { paint.getFontMetricsInt(it) }
        return width()
    }

    private val mark = Paint()

    override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
        val w = width().toFloat()
        canvas.withClip(x, top.toFloat(), x + w, bottom.toFloat()) {
            // A replacement draws its text itself, background spans included: the words found by a search.
            if (text is Spanned) for (span in text.getSpans(start, end, BackgroundColorSpan::class.java)) {
                val s = maxOf(text.getSpanStart(span), start)
                val e = minOf(text.getSpanEnd(span), end)
                if (s >= e) continue
                val left = x - scroll.x + paint.measureText(text, start, s)
                mark.color = span.backgroundColor
                drawRect(left, top.toFloat(), left + paint.measureText(text, s, e), bottom.toFloat(), mark)
            }
            drawText(text, start, end, x - scroll.x, y.toFloat(), paint)
        }
        val clear = ColorUtils.setAlphaComponent(style.surface, 0)
        if (scroll.x > 0) {
            fade.shader = LinearGradient(x, 0f, x + fadeWidth, 0f, style.surface, clear, Shader.TileMode.CLAMP)
            canvas.drawRect(x, top.toFloat(), x + fadeWidth, bottom.toFloat(), fade)
        }
        if (paint.measureText(text, start, end) - scroll.x > w) {
            fade.shader = LinearGradient(x + w - fadeWidth, 0f, x + w, 0f, clear, style.surface, Shader.TileMode.CLAMP)
            canvas.drawRect(x + w - fadeWidth, top.toFloat(), x + w, bottom.toFloat(), fade)
        }
    }
}

/**
 * Bullets, numbers, checkboxes and the bar of a quote, drawn in the indent of the
 * line. UpdateLayout makes the field rewrap the line when the span arrives: a
 * margin alone would only be repainted, over text still wrapped without it.
 */
class ListLineSpan(private val marker: MarkerSpan, private val style: NoteStyle) :
    CharacterStyle(), LeadingMarginSpan, UpdateLayout, LineSpan {

    override fun getLeadingMargin(first: Boolean) =
        if (marker.block.type == BlockType.QUOTE) style.quoteIndent else style.indent * (1 + nesting())

    /** How many indents a nested list item sits further in. */
    private fun nesting() = if (marker.block.isListItem) marker.block.depth else 0

    override fun updateDrawState(tp: TextPaint) {
        when {
            marker.block.type == BlockType.QUOTE -> tp.color = style.dimmed
            marker.block.type == BlockType.CHECKBOX && marker.block.checked -> {
                tp.isStrikeThruText = true
                tp.color = style.dimmed
            }
        }
    }

    override fun drawLeadingMargin(
        c: Canvas, p: Paint, x: Int, dir: Int, top: Int, baseline: Int, bottom: Int,
        text: CharSequence, start: Int, end: Int, first: Boolean, layout: Layout?,
    ) {
        // The bar runs down every line of the quote, wrapped ones included, and
        // joins up with the quoted lines above and below.
        if (marker.block.type == BlockType.QUOTE) {
            val color = p.color
            val paintStyle = p.style
            p.color = style.quoteBar
            p.style = Paint.Style.FILL
            c.drawRect(x + style.dp(2f), top.toFloat(), x + style.dp(5f), bottom.toFloat(), p)
            p.color = color
            p.style = paintStyle
            return
        }
        if (!first) return
        val color = p.color
        val paintStyle = p.style
        val align = p.textAlign
        val stroke = p.strokeWidth
        val left = x.toFloat() + style.indent * nesting()
        val cy = baseline + (p.ascent() + p.descent()) / 2
        when (marker.block.type) {
            BlockType.BULLET -> drawBullet(c, p, left + style.indent / 2f - style.dp(4f), cy)
            BlockType.NUMBERED -> {
                p.textAlign = Paint.Align.RIGHT
                c.drawText("${marker.number}.", left + style.indent - style.dp(8f), baseline.toFloat(), p)
            }
            BlockType.CHECKBOX -> drawCheckbox(c, p, left, cy)
            else -> Unit
        }
        p.color = color
        p.style = paintStyle
        p.textAlign = align
        p.strokeWidth = stroke
    }

    /** A dot, a ring and a square in turn, so each level of a nested list has its own bullet. */
    private fun drawBullet(c: Canvas, p: Paint, cx: Float, cy: Float) {
        val r = style.dp(3f)
        when (nesting() % 3) {
            0 -> {
                p.style = Paint.Style.FILL
                c.drawCircle(cx, cy, r, p)
            }
            1 -> {
                p.style = Paint.Style.STROKE
                p.strokeWidth = style.dp(1.3f)
                c.drawCircle(cx, cy, r, p)
            }
            else -> {
                p.style = Paint.Style.FILL
                c.drawRect(cx - r * 0.85f, cy - r * 0.85f, cx + r * 0.85f, cy + r * 0.85f, p)
            }
        }
    }

    private fun drawCheckbox(c: Canvas, p: Paint, left: Float, cy: Float) {
        val size = p.textSize * 0.95f
        val l = left + (style.indent - size) / 2 - style.dp(4f)
        val t = cy - size / 2
        val radius = size / 2
        p.color = style.accent
        p.strokeWidth = style.dp(2f)
        if (marker.block.checked) {
            p.style = Paint.Style.FILL
            c.drawRoundRect(l, t, l + size, t + size, radius, radius, p)
            p.color = style.tick
            p.style = Paint.Style.STROKE
            p.strokeCap = Paint.Cap.ROUND
            val check = Path().apply {
                moveTo(l + size * 0.22f, t + size * 0.52f)
                lineTo(l + size * 0.42f, t + size * 0.72f)
                lineTo(l + size * 0.78f, t + size * 0.30f)
            }
            c.drawPath(check, p)
            p.strokeCap = Paint.Cap.BUTT
        } else {
            p.color = style.box
            p.strokeWidth = style.dp(1.4f)
            p.style = Paint.Style.STROKE
            val inset = p.strokeWidth / 2
            c.drawRoundRect(l + inset, t + inset, l + size - inset, t + size - inset, radius, radius, p)
        }
    }
}

/**
 * The margin every line of the note starts with. It holds the arrow that folds a
 * heading, so the arrow sits outside the text and headings line up with it.
 */
class GutterSpan(private val style: NoteStyle) : LeadingMarginSpan {
    override fun getLeadingMargin(first: Boolean) = style.gutter

    override fun drawLeadingMargin(
        c: Canvas, p: Paint, x: Int, dir: Int, top: Int, baseline: Int, bottom: Int,
        text: CharSequence, start: Int, end: Int, first: Boolean, layout: Layout?,
    ) {
        // The title, the first line, has no arrow: it cannot be folded.
        if (!first || start == 0 || text !is Spanned || start >= text.length || text[start] != MARK) return
        val marker = text.getSpans(start, start + 1, MarkerSpan::class.java).firstOrNull() ?: return
        if (marker.block.type != BlockType.HEADING) return
        val cx = x + style.gutter / 2f
        val cy = baseline - p.textSize * headingScale(marker.block.level) * 0.35f
        val half = style.dp(5f)
        // A chevron, as on the Mac: right while the section is folded, down while it shows.
        val arrow = Path().apply {
            if (marker.hidden != null) {
                moveTo(cx - half * 0.35f, cy - half * 0.75f)
                lineTo(cx + half * 0.45f, cy)
                lineTo(cx - half * 0.35f, cy + half * 0.75f)
            } else {
                moveTo(cx - half * 0.75f, cy - half * 0.35f)
                lineTo(cx, cy + half * 0.45f)
                lineTo(cx + half * 0.75f, cy - half * 0.35f)
            }
        }
        val color = p.color
        val paintStyle = p.style
        val stroke = p.strokeWidth
        val cap = p.strokeCap
        val join = p.strokeJoin
        p.color = style.chevron
        p.style = Paint.Style.STROKE
        p.strokeWidth = style.dp(1.8f)
        p.strokeCap = Paint.Cap.ROUND
        p.strokeJoin = Paint.Join.ROUND
        c.drawPath(arrow, p)
        p.color = color
        p.style = paintStyle
        p.strokeWidth = stroke
        p.strokeCap = cap
        p.strokeJoin = join
    }
}

class CodeSpan(private val background: Int, private val color: Int) : MetricAffectingSpan() {
    override fun updateMeasureState(tp: TextPaint) {
        tp.typeface = Typeface.create(Typeface.MONOSPACE, tp.typeface?.style ?: Typeface.NORMAL)
    }

    override fun updateDrawState(tp: TextPaint) {
        updateMeasureState(tp)
        tp.bgColor = background
        tp.color = color
    }
}

/**
 * A table drawn as a grid over the single [TABLE_CHAR] it replaces. Cells do
 * not wrap: each column is as wide as its longest text. A table narrower than
 * the note is stretched to its width; a wider one keeps its columns and
 * scrolls sideways by [scroll], with a fade at an edge that has more beyond it.
 */
/** A table or a picture: one [TABLE_CHAR] on a line of its own, drawn as a whole. */
abstract class ObjectSpan : ReplacementSpan() {
    /** Where it was last drawn, in the coordinates of the field's text layout; empty until then. */
    val shown = RectF()
}

class TableSpan(var table: MdTable, private val style: NoteStyle, private val width: () -> Int) : ObjectSpan() {

    val scroll = CodeScroll()

    /** Words a search found in the cells, marked in [markColor]; empty for none. */
    var marks: List<String> = emptyList()
    var markColor = 0
    private val markPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val markPath = Path()

    fun hasMarks(words: List<String>) = table.rows.any { row -> row.any { NoteSearch.hits(it, words).isNotEmpty() } }

    /**
     * Scrolls the table sideways, if it is wider than the note, to show the
     * first cell with a word found. Known only once the table was measured.
     */
    fun revealMarks() {
        if (marks.isEmpty() || widths.isEmpty()) return
        val column = table.rows.firstNotNullOfOrNull { row -> row.indexOfFirst { NoteSearch.hits(it, marks).isNotEmpty() }.takeIf { it >= 0 } } ?: return
        val left = widths.take(column).sum()
        val right = left + widths[column]
        val w = width()
        if (left < scroll.x || right > scroll.x + w) scroll.x = (left - style.gutter).toInt().coerceIn(0, scroll.max)
    }

    private var cells: List<List<StaticLayout>> = emptyList()
    private var widths = FloatArray(0)
    private var heights = IntArray(0)
    private var measuredFor: Triple<MdTable, Int, Float>? = null
    private val body = TextPaint(Paint.ANTI_ALIAS_FLAG)
    private val fade = Paint()
    private val fadeWidth = style.dp(16f)
    private val minColumn = style.dp(48f)

    private fun measure(paint: Paint): Int {
        val w = width()
        val key = Triple(table, w, paint.textSize)
        if (key != measuredFor) {
            measuredFor = key
            body.set(paint)
            val columns = table.columns.coerceAtLeast(1)
            val text = table.rows.map { row -> List(columns) { row.getOrElse(it) { "" } } }
            val natural = FloatArray(columns) { c ->
                maxOf(minColumn, (text.maxOfOrNull { body.measureText(it[c]) } ?: 0f) + 2 * style.cellPadding)
            }
            // Room to spare goes to the columns evenly, as a table filling the note did before.
            val spare = (w - natural.sum()).coerceAtLeast(0f) / columns
            widths = FloatArray(columns) { natural[it] + spare }
            cells = text.map { row ->
                row.mapIndexed { c, cell ->
                    val inner = (widths[c] - 2 * style.cellPadding).toInt().coerceAtLeast(1)
                    StaticLayout.Builder.obtain(cell, 0, cell.length, body, inner).build()
                }
            }
            heights = IntArray(cells.size) { r -> (cells[r].maxOfOrNull { it.height } ?: 0) + 2 * style.cellPadding }
            scroll.max = (widths.sum() - w).toInt().coerceAtLeast(0)
            scroll.x = scroll.x.coerceIn(0, scroll.max)
        }
        return heights.sum()
    }

    override fun getSize(paint: Paint, text: CharSequence?, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
        val height = measure(paint)
        fm?.apply {
            ascent = -(height + style.tableGap)
            top = ascent
            descent = style.tableGap
            bottom = descent
        }
        return width()
    }

    override fun draw(canvas: Canvas, text: CharSequence?, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
        val height = measure(paint)
        if (heights.isEmpty()) return
        val w = width().toFloat()
        val total = widths.sum()
        val tableTop = (y - height).toFloat()
        val tableBottom = tableTop + height
        shown.set(x, tableTop, x + min(w, widths.sum()), tableBottom)
        val color = paint.color
        val paintStyle = paint.style
        val stroke = paint.strokeWidth
        // Half a line more on each side keeps the outer border inside the clip.
        val half = style.dp(0.5f)
        canvas.withClip(x - half, tableTop - half, x + w + half, tableBottom + half) {
            val left = x - scroll.x
            body.color = color
            var rowTop = tableTop
            cells.forEachIndexed { r, row ->
                var cellLeft = left
                row.forEachIndexed { c, cell ->
                    withTranslation(cellLeft + style.cellPadding, rowTop + style.cellPadding) {
                        if (marks.isNotEmpty()) {
                            markPaint.color = markColor
                            for (hit in NoteSearch.hits(cell.text.toString(), marks)) {
                                markPath.reset()
                                cell.getSelectionPath(hit.first, hit.last + 1, markPath)
                                drawPath(markPath, markPaint)
                            }
                        }
                        cell.draw(this)
                    }
                    cellLeft += widths[c]
                }
                rowTop += heights[r]
            }

            paint.style = Paint.Style.STROKE
            paint.strokeWidth = style.dp(1f)
            paint.color = style.outline
            drawRect(left, tableTop, left + total, tableBottom, paint)
            var lineY = tableTop
            for (r in 0 until heights.size - 1) {
                lineY += heights[r]
                drawLine(left, lineY, left + total, lineY, paint)
            }
            var lineX = left
            for (c in 0 until widths.size - 1) {
                lineX += widths[c]
                drawLine(lineX, tableTop, lineX, tableBottom, paint)
            }
        }
        paint.color = color
        paint.style = paintStyle
        paint.strokeWidth = stroke

        val background = style.background
        val clear = ColorUtils.setAlphaComponent(background, 0)
        if (scroll.x > 0) {
            fade.shader = LinearGradient(x, 0f, x + fadeWidth, 0f, background, clear, Shader.TileMode.CLAMP)
            canvas.drawRect(x, tableTop, x + fadeWidth, tableBottom, fade)
        }
        if (scroll.x < scroll.max) {
            fade.shader = LinearGradient(x + w - fadeWidth, 0f, x + w, 0f, clear, background, Shader.TileMode.CLAMP)
            canvas.drawRect(x + w - fadeWidth, tableTop, x + w, tableBottom, fade)
        }
    }
}

/**
 * A picture in the note, as the Notes app on the Mac shows one: as wide as the
 * note, in its own proportions, with rounded corners. A tall picture is kept
 * from filling more than [MAX_ASPECT] times its width in height. [load] reads
 * the file at the size it is shown; a missing file is drawn as an empty frame.
 */
class NoteImageSpan(
    var image: MdImage,
    private val style: NoteStyle,
    private val width: () -> Int,
    private val load: (MdImage, Int) -> Bitmap?,
) : ObjectSpan() {

    private var bitmap: Bitmap? = null
    private var loadedFor = -1

    private val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val clip = Path()

    private fun size(): Pair<Int, Int> {
        val w = width()
        if (loadedFor != w) {
            bitmap = load(image, w)
            loadedFor = w
        }
        val b = bitmap ?: return w to (w * 9 / 16)
        var shownWidth = minOf(w, b.width)
        var shownHeight = shownWidth * b.height / b.width
        val tallest = (w * MAX_ASPECT).toInt()
        if (shownHeight > tallest) {
            shownWidth = shownWidth * tallest / shownHeight
            shownHeight = tallest
        }
        return shownWidth to shownHeight
    }

    fun bitmap(): Bitmap? = bitmap

    /** Forgets the picture read so far, so the next layout reads the file again. */
    fun reload() {
        loadedFor = -1
    }

    override fun getSize(paint: Paint, text: CharSequence?, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
        val (_, h) = size()
        fm?.apply {
            ascent = -(h + style.tableGap)
            top = ascent
            descent = style.tableGap
            bottom = descent
        }
        return width()
    }

    override fun draw(canvas: Canvas, text: CharSequence?, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
        val (w, h) = size()
        val imageTop = (y - h).toFloat()
        shown.set(x, imageTop, x + w, imageTop + h)
        val radius = style.dp(10f)
        clip.reset()
        clip.addRoundRect(shown, radius, radius, Path.Direction.CW)
        val b = bitmap
        if (b == null) {
            val color = paint.color
            val paintStyle = paint.style
            paint.color = style.surface
            paint.style = Paint.Style.FILL
            canvas.drawPath(clip, paint)
            paint.color = color
            paint.style = paintStyle
            return
        }
        canvas.withClip(clip) { drawBitmap(b, null, shown, this@NoteImageSpan.paint) }
    }

    private companion object {
        const val MAX_ASPECT = 1.25f
    }
}

/**
 * A file attached to the note, shown as a tile: a badge with its kind, its
 * name, and below the name its kind and size. A recording has a play button
 * for a badge and shows how long it is, and while it plays how far it got.
 * The dots at the end open what can be done with the file.
 */
class NoteFileSpan(
    var file: MdFile,
    private val style: NoteStyle,
    private val width: () -> Int,
    private val info: (MdFile) -> NoteFiles.Info,
) : ObjectSpan() {

    enum class Part { BADGE, BODY, MENU }

    var playing = false
    var position = 0L

    private var known: NoteFiles.Info? = null
    private val details get() = known ?: info(file).also { known = it }

    /** Forgets the size and length read so far, for a recording just finished. */
    fun reload() {
        known = null
    }

    val duration get() = details.duration

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val text = TextPaint(Paint.ANTI_ALIAS_FLAG)
    private val box = RectF()
    private val glyph = Path()

    private fun tileWidth() = min(width(), style.dp(440f).roundToInt())

    private fun tileHeight() = style.dp(64f).roundToInt()

    /** Which part of the tile [x] falls on, in the coordinates it was drawn in. */
    fun partAt(x: Float): Part = when {
        x < shown.left + style.dp(60f) -> Part.BADGE
        x > shown.right - style.dp(48f) -> Part.MENU
        else -> Part.BODY
    }

    override fun getSize(paint: Paint, text: CharSequence?, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
        fm?.apply {
            ascent = -(tileHeight() + style.tableGap)
            top = ascent
            descent = style.tableGap
            bottom = descent
        }
        return width()
    }

    override fun draw(canvas: Canvas, text: CharSequence?, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
        val w = tileWidth()
        val h = tileHeight()
        val tileTop = (y - h).toFloat()
        shown.set(x, tileTop, x + w, tileTop + h)
        fill.color = style.surface
        canvas.drawRoundRect(shown, style.dp(12f), style.dp(12f), fill)

        val pad = style.dp(10f)
        val badge = style.dp(44f)
        box.set(x + pad, tileTop + (h - badge) / 2, x + pad + badge, tileTop + (h + badge) / 2)
        fill.color = style.primary
        canvas.drawRoundRect(box, style.dp(10f), style.dp(10f), fill)
        fill.color = style.onPrimary
        if (file.isAudio) drawPlay(canvas, box.centerX(), box.centerY(), style.dp(9f)) else {
            this.text.set(paint)
            this.text.color = style.onPrimary
            this.text.typeface = Typeface.DEFAULT_BOLD
            this.text.textSize = style.dp(11f)
            this.text.textAlign = Paint.Align.CENTER
            val kind = file.extension.uppercase().take(4).ifEmpty { "FILE" }
            canvas.drawText(kind, box.centerX(), box.centerY() - (this.text.ascent() + this.text.descent()) / 2, this.text)
        }

        val textLeft = box.right + pad * 1.2f
        val menuLeft = shown.right - style.dp(44f)
        val room = menuLeft - textLeft
        this.text.set(paint)
        this.text.textAlign = Paint.Align.LEFT
        this.text.typeface = Typeface.create(paint.typeface, Typeface.BOLD)
        this.text.color = paint.color
        val name = android.text.TextUtils.ellipsize(file.name, this.text, room, android.text.TextUtils.TruncateAt.MIDDLE)
        canvas.drawText(name, 0, name.length, textLeft, tileTop + h * 0.44f, this.text)

        this.text.typeface = Typeface.DEFAULT
        this.text.textSize = paint.textSize * 0.8f
        this.text.color = style.dimmed
        val about = details
        val detail = if (file.isAudio) {
            if (playing || position > 0) clock(position) + " / " + clock(about.duration) else clock(about.duration)
        } else {
            listOfNotNull(file.extension.uppercase().ifEmpty { null }, size(about.size)).joinToString(" · ")
        }
        canvas.drawText(detail, textLeft, tileTop + h * 0.76f, this.text)

        if (file.isAudio && about.duration > 0 && (playing || position > 0)) {
            val barTop = tileTop + h - style.dp(8f)
            val barHeight = style.dp(3f)
            fill.color = style.outline
            box.set(textLeft, barTop, menuLeft, barTop + barHeight)
            canvas.drawRoundRect(box, barHeight, barHeight, fill)
            fill.color = style.primary
            box.right = textLeft + room * (position.toFloat() / about.duration).coerceIn(0f, 1f)
            canvas.drawRoundRect(box, barHeight, barHeight, fill)
        }

        // The dots that open the menu.
        fill.color = style.dimmed
        val dotsX = shown.right - style.dp(24f)
        for (i in -1..1) canvas.drawCircle(dotsX, shown.centerY() + i * style.dp(6f), style.dp(2f), fill)
    }

    private fun drawPlay(canvas: Canvas, cx: Float, cy: Float, r: Float) {
        if (playing) {
            val bar = r * 0.55f
            canvas.drawRoundRect(cx - r * 0.8f, cy - r, cx - r * 0.8f + bar, cy + r, bar / 3, bar / 3, fill)
            canvas.drawRoundRect(cx + r * 0.8f - bar, cy - r, cx + r * 0.8f, cy + r, bar / 3, bar / 3, fill)
            return
        }
        glyph.reset()
        glyph.moveTo(cx - r * 0.7f, cy - r)
        glyph.lineTo(cx + r, cy)
        glyph.lineTo(cx - r * 0.7f, cy + r)
        glyph.close()
        canvas.drawPath(glyph, fill)
    }

    private companion object {
        fun clock(ms: Long): String {
            val seconds = ms / 1000
            return "%d:%02d".format(seconds / 60, seconds % 60)
        }

        fun size(bytes: Long): String? = when {
            bytes <= 0 -> null
            bytes < 1024 -> "$bytes B"
            bytes < 1024 * 1024 -> "%.0f KB".format(Locale.ROOT, bytes / 1024.0)
            else -> "%.1f MB".format(Locale.ROOT, bytes / 1024.0 / 1024.0)
        }
    }
}

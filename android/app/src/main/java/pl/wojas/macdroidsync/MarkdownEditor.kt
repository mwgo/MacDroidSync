package pl.wojas.macdroidsync

import android.graphics.Bitmap
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Editable
import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextPaint
import android.text.TextWatcher
import android.text.style.BackgroundColorSpan
import android.text.style.StyleSpan
import androidx.core.graphics.ColorUtils
import android.text.style.UnderlineSpan
import android.os.SystemClock
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * WYSIWYG Markdown on top of a plain text field. The note lives in the field's
 * Editable as text and spans: a line that is not a paragraph starts with a
 * [MARK] carrying a [MarkerSpan], a table or a picture is one [TABLE_CHAR]
 * carrying a [TableSpan], a [NoteImageSpan] or a [NoteFileSpan], and inline styles are ordinary character spans. Markdown typed
 * into the field is turned into those as soon as it is complete, and
 * [toMarkdown] turns them back.
 */
class MarkdownEditor(
    private val view: MarkdownEditText,
    private val onTableTap: (TableSpan) -> Unit,
    /** Reads a picture of the note at about the given width, or null when it cannot. */
    private val loadImage: (MdImage, Int) -> Bitmap?,
    /** How big an attached file is, and how long a recording. */
    private val fileInfo: (MdFile) -> NoteFiles.Info,
) : TextWatcher {

    private val style = NoteStyle(view.context)
    private val gutter = GutterSpan(style)
    private var applying = false
    private var changeStart = 0
    private var changeBefore = 0
    private var changeCount = 0
    private val pendingRestore = mutableListOf<Pair<Int, Spanned>>()
    private var inTextChange = false

    /** Inline spans over text about to be replaced, with where they were. */
    private val replacedStyles = mutableListOf<Triple<Any, Int, Int>>()

    /** Styles of text just deleted, relative to where it was, and when. */
    private val deletedStyles = mutableListOf<Triple<Any, Int, Int>>()
    private var deletedAt = -1
    private var deletedTime = 0L
    private var lastSelection = -1 to -1

    /** Styles the toolbar switched on for the next characters typed at the caret. */
    private val typingStyles = mutableSetOf<Inline>()

    /** What the toolbar shows as switched on for the caret or the selection. */
    /** [tasks] counts the note's checkboxes, folded ones too, and [open] those not ticked. */
    data class State(val inline: Set<Inline>, val block: Block, val allFolded: Boolean, val tasks: Int, val open: Int)

    var onStateChanged: ((State) -> Unit)? = null

    private val text: Editable get() = view.text!!

    // Dragging the handles leftwards puts the selection's start after its end.
    private val selStart: Int get() = max(min(view.selectionStart, view.selectionEnd), 0)
    private val selEnd: Int get() = max(max(view.selectionStart, view.selectionEnd), 0)

    init {
        view.addTextChangedListener(this)
        view.onTap = ::tap
        view.onWidthChanged = ::refreshTables
        view.onSelection = ::selectionChanged
        view.codeScrollAt = ::codeScrollAt
        view.onCodeScrolled = ::codeScrolled
        view.onMoveStart = ::startMove
        view.onMoveTo = ::moveTo
        view.onMoveEnd = ::endMove
        view.onSelectLifted = ::selectLifted
        view.setMoveColors(ColorUtils.setAlphaComponent(style.primary, 0x30), style.primary)
    }

    fun setMarkdown(markdown: String) = edit {
        val lines = Markdown.parse(markdown)
        val b = SpannableStringBuilder()
        lines.forEachIndexed { i, line ->
            if (i > 0) b.append('\n')
            append(b, line)
        }
        // Somewhere to put the caret below a table that ends the note.
        if (lines.lastOrNull()?.block?.type.let { it == BlockType.TABLE || it == BlockType.IMAGE || it == BlockType.FILE }) b.append('\n')
        view.setText(b)
        normalize(text)
        view.setSelection(0)
    }

    fun toMarkdown(): String = Markdown.toMarkdown(linesOf(text))

    /** Adds an empty 2×2 table below the caret's line and opens it for editing. */
    fun insertTable() {
        val span = TableSpan(MdTable(listOf(listOf("", ""), listOf("", ""))), style, ::tableWidth)
        edit {
            val e = text
            val cursor = selStart
            val ls = lineStart(e, cursor)
            val le = lineEnd(e, cursor)
            val at = if (ls == le) ls else le + 1
            if (at > ls) e.insert(le, "\n")
            e.insert(at, TABLE_CHAR.toString())
            e.setSpan(span, at, at + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (at + 1 == e.length) e.append('\n')
            normalize(e)
            view.setSelection(min(at + 2, e.length))
        }
        onTableTap(span)
    }

    // region Search marks

    private val searchMarks = mutableListOf<BackgroundColorSpan>()

    /**
     * Marks every word of a search in the note, the cells of tables included,
     * and returns where the first one is, or null when there is none. The
     * marks are not part of the note: they are never written out.
     */
    fun markSearch(words: List<String>, color: Int): Int? {
        clearSearchMarks()
        if (words.isEmpty()) return null
        val e = text
        var first: Int? = null
        for (hit in NoteSearch.hits(e.toString(), words)) {
            val span = BackgroundColorSpan(color)
            e.setSpan(span, hit.first, hit.last + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            searchMarks += span
            first = min(first ?: hit.first, hit.first)
        }
        for (table in e.getSpans(0, e.length, TableSpan::class.java)) {
            if (!table.hasMarks(words)) continue
            table.marks = words
            table.markColor = color
            refresh(e, table)
            first = min(first ?: e.getSpanStart(table), e.getSpanStart(table))
        }
        return first
    }

    fun clearSearchMarks() {
        val e = text
        searchMarks.forEach(e::removeSpan)
        searchMarks.clear()
        for (table in e.getSpans(0, e.length, TableSpan::class.java)) {
            if (table.marks.isEmpty()) continue
            table.marks = emptyList()
            refresh(e, table)
        }
    }

    /**
     * Brings a mark at [at] into view sideways, where a code block shown
     * unwrapped or a wide table would otherwise hide it. Up and down is the
     * scroll view's part.
     */
    fun revealSideways(at: Int) = edit {
        val e = text
        tableAt(e, at)?.let {
            it.revealMarks()
            refresh(e, it)
            return@edit
        }
        val ls = lineStart(e, at)
        val codeView = markerAt(e, ls)?.codeView ?: return@edit
        if (e.getSpanStart(codeView) < 0) return@edit
        val scroll = codeScrollAt(0f, lineY(ls)) ?: codeView.scroll
        val x = codePaint().measureText(e, ls + 1, at)
        val w = codeWidth()
        if (x < scroll.x || x > scroll.x + w * 0.8f) scroll.x = (x - w / 3f).toInt().coerceIn(0, scroll.max)
        codeScrolled(scroll)
    }

    /** The middle of the line starting at [ls], in the field's own coordinates. */
    private fun lineY(ls: Int): Float {
        val layout = view.layout ?: return 0f
        val line = layout.getLineForOffset(ls)
        return view.totalPaddingTop + (layout.getLineTop(line) + layout.getLineBottom(line)) / 2f - view.scrollY
    }

    // endregion

    /** A picture tapped in the note, with where it is shown, in the field's own coordinates. */
    var onImageTap: ((NoteImageSpan, RectF) -> Unit)? = null

    /** Adds a picture on its own line below the caret's line. */
    fun insertImage(image: MdImage) = insertObject(imageSpan(image))

    /** Adds a file's tile on its own line below the caret's line. */
    fun insertFile(file: MdFile) = insertObject(fileSpan(file))

    private fun insertObject(span: ObjectSpan) = edit {
        val e = text
        val cursor = selStart
        val ls = lineStart(e, cursor)
        val le = lineEnd(e, cursor)
        val at = if (ls == le && ls > 0) ls else le + 1
        if (at > ls) e.insert(le, "\n")
        e.insert(at, TABLE_CHAR.toString())
        e.setSpan(span, at, at + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        if (at + 1 == e.length) e.append('\n')
        normalize(e)
        view.setSelection(min(at + 2, e.length))
    }

    /**
     * Where a picture or a table is drawn, in the field's own coordinates, or
     * null when it is no longer in the note or has not been drawn yet.
     */
    fun bounds(span: ObjectSpan): RectF? {
        if (text.getSpanStart(span) < 0 || span.shown.isEmpty) return null
        return RectF(span.shown).apply { offset(view.totalPaddingLeft.toFloat(), view.totalPaddingTop.toFloat()) }
    }

    /** Takes a picture or a file out of the note, with the line it stood on. */
    fun removeObject(span: ObjectSpan) = edit {
        val e = text
        val at = e.getSpanStart(span)
        if (at < 0) return@edit
        e.delete(at, if (at + 1 < e.length && e[at + 1] == '\n') at + 2 else at + 1)
        normalize(e)
    }

    /** Shows the picture's file again after it was changed, turned for instance. */
    fun reloadImage(span: NoteImageSpan) = edit {
        span.reload()
        refresh(text, span)
    }

    private fun imageSpan(image: MdImage) = NoteImageSpan(image, style, ::tableWidth, loadImage)

    /** Draws a file's tile anew, a recording playing on; the field keeps what it drew of the text otherwise. */
    fun redraw(span: ObjectSpan) = edit(quiet = true) { refresh(text, span) }

    private fun fileSpan(file: MdFile) = NoteFileSpan(file, style, ::tableWidth, fileInfo)

    /** A file tapped in the note, with the part of its tile the finger was on. */
    var onFileTap: ((NoteFileSpan, NoteFileSpan.Part) -> Unit)? = null

    /** Puts an edited table back, or removes it when [table] is null. */
    fun updateTable(span: TableSpan, table: MdTable?) = edit {
        val e = text
        val at = e.getSpanStart(span)
        if (at < 0) return@edit
        if (table == null) {
            e.delete(at, if (at + 1 < e.length && e[at + 1] == '\n') at + 2 else at + 1)
        } else {
            // A table opened and closed without a change leaves the note as it was.
            if (table == span.table) return@edit
            span.table = table
            refresh(e, span)
        }
        normalize(e)
    }

    // region Toolbar

    /**
     * Switches [style] on or off over the selection. Without a selection it
     * applies to what is typed next at the caret, until the caret moves.
     */
    fun toggleInline(style: Inline) {
        if (view.selectionStart < 0) return
        val start = selStart
        val end = selEnd
        if (start == end) {
            if (!typingStyles.remove(style)) typingStyles += style
            publishState()
            return
        }
        edit {
            val e = text
            val covered = covers(e, start, end, style)
            for (span in spansOf(e, start, end, style)) {
                val s = e.getSpanStart(span)
                val en = e.getSpanEnd(span)
                e.removeSpan(span)
                if (s < start) e.setSpan(inlineSpan(style), s, start, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                if (en > end) e.setSpan(inlineSpan(style), end, en, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            if (!covered) e.setSpan(inlineSpan(style), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }

    /** Makes the selected lines [type], or plain paragraphs when they all are already. */
    fun toggleBlock(type: BlockType) = edit {
        val e = text
        val starts = selectedLineStarts(e)
        setBlocks(e, starts, if (starts.all { markerAt(e, it)?.block?.type == type }) null else Block(type))
    }

    /** Steps the selected lines through H1, H2, H3 and back to a paragraph. */
    fun cycleHeading() = edit {
        val e = text
        val starts = selectedLineStarts(e)
        val level = markerAt(e, starts.first())?.block?.takeIf { it.type == BlockType.HEADING }?.level ?: 0
        setBlocks(e, starts, if (level >= 3) null else Block(BlockType.HEADING, level = level + 1))
    }

    private fun setBlocks(e: Editable, starts: List<Int>, block: Block?) {
        // From the last line up, so that unfolding a heading moves nothing still to do.
        for (ls in starts.asReversed()) {
            if (ls == 0 || objectAt(e, ls) != null) continue
            val marker = markerAt(e, ls)
            when {
                block == null -> if (marker != null) {
                    expand(e, marker)
                    e.removeSpan(marker)
                    e.delete(ls, ls + 1)
                }
                marker != null -> {
                    if (block.type != BlockType.HEADING) expand(e, marker)
                    marker.block = block
                }
                else -> {
                    e.insert(ls, MARK.toString())
                    e.setSpan(MarkerSpan(block), ls, ls + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
            }
            if (block?.type == BlockType.CODE) stripInline(e, ls)
        }
        normalize(e)
    }

    /** Code is plain text: Markdown has no styles inside a code block, so the line loses its own. */
    private fun stripInline(e: Editable, ls: Int) {
        val le = lineEnd(e, ls)
        for (span in e.getSpans(ls, le, Any::class.java)) {
            if (inlineOf(span).isNotEmpty() && e.getSpanEnd(span) > ls && e.getSpanStart(span) < le) {
                val s = e.getSpanStart(span)
                val en = e.getSpanEnd(span)
                e.removeSpan(span)
                // What the span covered on the lines around it stays styled.
                if (s < ls) e.setSpan(inlineSpan(inlineOf(span).first()), s, ls, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                if (en > le) e.setSpan(inlineSpan(inlineOf(span).first()), le, en, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
    }

    private fun selectedLineStarts(e: Editable): List<Int> {
        val end = selEnd
        val starts = mutableListOf<Int>()
        var s = lineStart(e, selStart)
        while (true) {
            starts += s
            val le = lineEnd(e, s)
            // A selection ending at the start of a line does not take that line in.
            if (le + 1 >= end || le >= e.length) break
            s = le + 1
        }
        return starts
    }

    private fun selectionChanged(start: Int, end: Int) {
        if (applying || inTextChange) return
        if (widenToLifted(start, end)) return
        if (start to end != lastSelection) typingStyles.clear()
        lastSelection = start to end
        updateCodeViews()
        publishState()
    }

    private fun publishState() {
        val listener = onStateChanged ?: return
        val e = text
        val start = selStart
        val end = selEnd
        val inline = if (start == end) typingStyles.toSet() else Inline.entries.filter { covers(e, start, end, it) }.toSet()
        val tasks = tasksOf(e)
        listener(State(inline, markerAt(e, lineStart(e, start))?.block ?: Block(BlockType.PARAGRAPH), allFolded(e), tasks.size, tasks.count { !it.checked }))
    }

    private fun tasksOf(t: Spanned): List<Block> = t.getSpans(0, t.length, MarkerSpan::class.java).flatMap { marker ->
        val own = if (marker.block.type == BlockType.CHECKBOX) listOf(marker.block) else emptyList()
        own + (marker.hidden?.let { tasksOf(it) } ?: emptyList())
    }

    private fun spansOf(e: Spanned, start: Int, end: Int, style: Inline): List<Any> =
        e.getSpans(start, end, Any::class.java).filter {
            inlineOf(it) == listOf(style) && e.getSpanEnd(it) > start && e.getSpanStart(it) < end
        }

    /** Whether every character of [start, end) that is text rather than structure has [style]. */
    private fun covers(e: Spanned, start: Int, end: Int, style: Inline): Boolean {
        if (end <= start) return false
        val styled = BooleanArray(end - start)
        for (span in spansOf(e, start, end, style)) {
            for (i in max(e.getSpanStart(span), start) until min(e.getSpanEnd(span), end)) styled[i - start] = true
        }
        var any = false
        for (i in start until end) {
            if (e[i] == '\n' || e[i] == MARK || e[i] == TABLE_CHAR) continue
            if (!styled[i - start]) return false
            any = true
        }
        return any
    }

    /** Gives [from, to) the [style], growing a span that ends where the new text starts. */
    private fun extendStyle(e: Editable, style: Inline, from: Int, to: Int) {
        val touching = e.getSpans(from, from, Any::class.java).firstOrNull {
            inlineOf(it) == listOf(style) && e.getSpanStart(it) <= from && e.getSpanEnd(it) >= from
        }
        if (touching != null) {
            e.setSpan(touching, min(e.getSpanStart(touching), from), max(e.getSpanEnd(touching), to), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        } else {
            e.setSpan(inlineSpan(style), from, to, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }

    // endregion

    // region Moving paragraphs and sections

    /** A paragraph or section being dragged: [start, end) of its text and where it may land. */
    private class Move(val start: Int, val end: Int, val targets: List<Int>) {
        var target = start
        fun staysPut() = target == start || target == end + 1
    }

    private var move: Move? = null

    /** What the last long press lifted, for selecting it when it was put down where it was. */
    private var lifted: Pair<Int, Int>? = null

    /** Lifts the paragraph or section under (x, y); false when there is nothing there to move. */
    private fun startMove(x: Float, y: Float): Boolean {
        val layout = view.layout ?: return false
        val ly = (y - view.totalPaddingTop).toInt()
        if (ly < 0 || ly > layout.height) return false
        val e = text
        val ls = lineStart(e, layout.getLineStart(layout.getLineForVertical(ly)))
        val (start, end) = unitAt(e, ls) ?: return false
        val targets = dropTargets(e, start, end)
        if (targets.all { it == start || it == end + 1 }) return false
        move = Move(start, end, targets)
        moveTo(y)
        return true
    }

    /** The range to widen the field's own selection to, and until when it may still try to shrink it. */
    private var liftedSelection: Pair<Int, Int>? = null
    private var liftedUntil = 0L

    /**
     * The field selects the word under the finger, and smart selection may set
     * it again a moment later, so for a short while any smaller selection
     * inside what was lifted is widened back to all of it.
     */
    private fun selectLifted() {
        val (start, end) = lifted ?: return
        lifted = null
        val e = text
        if (end > e.length) return
        // The caret never stands before the mark that starts a line.
        val from = if (start < e.length && e[start] == MARK) start + 1 else start
        liftedSelection = from to end
        liftedUntil = SystemClock.uptimeMillis() + LIFTED_SELECTION_WINDOW
        view.setSelection(from, end)
    }

    private fun widenToLifted(start: Int, end: Int): Boolean {
        val (from, to) = liftedSelection ?: return false
        if (SystemClock.uptimeMillis() > liftedUntil) {
            liftedSelection = null
            return false
        }
        // A press past the end of the text gives only a caret, which is widened as well.
        if (start < from || end > to || (start == from && end == to)) return false
        view.post { if (liftedSelection != null) view.setSelection(from, to) }
        return true
    }

    private fun moveTo(y: Float) {
        val m = move ?: return
        val layout = view.layout ?: return
        val ly = y - view.totalPaddingTop
        m.target = m.targets.minByOrNull { abs(boundaryY(layout, it) - ly) } ?: return
        val pad = view.totalPaddingTop.toFloat()
        view.showMove(
            layout.getLineTop(layout.getLineForOffset(m.start)) + pad,
            layout.getLineBottom(layout.getLineForOffset(m.end)) + pad,
            boundaryY(layout, m.target) + pad,
        )
    }

    private fun endMove(commit: Boolean) {
        val m = move ?: return
        move = null
        lifted = m.start to m.end
        view.hideMove()
        if (!commit || m.staysPut()) return
        edit {
            moveText(text, m.start, m.end, m.target)
            normalize(text)
        }
    }

    /**
     * What a long press lifts: a heading with its section (only the heading
     * line while it is folded, the section travelling inside it), a whole code
     * block, or else the one line, which is a paragraph, a list item, a quote
     * line or a table. An empty line has nothing to move.
     */
    private fun unitAt(e: Spanned, ls: Int): Pair<Int, Int>? {
        if (ls == 0) return null
        val le = lineEnd(e, ls)
        val marker = markerAt(e, ls)
        return when {
            marker?.block?.type == BlockType.HEADING -> ls to if (marker.hidden != null) le else sectionEndOffset(e, ls)
            marker?.block?.type == BlockType.CODE -> codeRun(e, ls)
            le == ls -> null
            else -> ls to le
        }
    }

    private fun isCode(e: Spanned, ls: Int) = markerAt(e, ls)?.block?.type == BlockType.CODE

    private fun codeRun(e: Spanned, ls: Int): Pair<Int, Int> {
        var start = ls
        while (start > 0 && isCode(e, lineStart(e, start - 1))) start = lineStart(e, start - 1)
        var end = lineEnd(e, ls)
        while (end < e.length && isCode(e, end + 1)) end = lineEnd(e, end + 1)
        return start to end
    }

    /**
     * The line starts the lifted text may be put before. A section lands only
     * before a heading of its level or higher, or at the end, so it never cuts
     * another section in two; anything else lands between any two lines except
     * inside a code block.
     */
    private fun dropTargets(e: Spanned, start: Int, end: Int): List<Int> {
        val heading = markerAt(e, start)?.block?.takeIf { it.type == BlockType.HEADING }
        val targets = mutableListOf<Int>()
        for (s in lineStarts(e)) {
            if (s == 0 || s in start + 1..end) continue
            val allowed = when {
                s == start || s == end + 1 -> true
                heading != null -> s == e.length || markerAt(e, s)?.block?.let { it.type == BlockType.HEADING && it.level <= heading.level } == true
                else -> !(isCode(e, s) && s > 0 && isCode(e, lineStart(e, s - 1)))
            }
            if (allowed) targets += s
        }
        // After the last line, when the note does not end with an empty one that already offers it.
        if (e.isNotEmpty() && e[e.length - 1] != '\n' && end < e.length) targets += e.length
        return targets
    }

    private fun boundaryY(layout: Layout, at: Int): Float {
        val e = text
        return if (at >= e.length && (e.isEmpty() || e[e.length - 1] != '\n')) layout.height.toFloat()
        else layout.getLineTop(layout.getLineForOffset(at)).toFloat()
    }

    private fun moveText(e: Editable, start: Int, end: Int, target: Int) {
        val moved = copyContained(e, start, end)
        // The newline after the text goes with it, or the one before for the last line.
        val from = if (end < e.length) start else max(start - 1, 0)
        val to = if (end < e.length) end + 1 else end
        e.delete(from, to)
        val at = (if (target > start) target - (to - from) else target).coerceIn(0, e.length)
        if (at == e.length && at > 0 && e[at - 1] != '\n') {
            e.insert(at, "\n")
            e.insert(at + 1, moved)
        } else {
            e.insert(at, "\n")
            e.insert(at, moved)
        }
    }

    // endregion

    // region Typing

    override fun beforeTextChanged(s: CharSequence, start: Int, count: Int, after: Int) {
        if (applying) return
        inTextChange = true
        if (count == 0 || s !is Spanned) return
        val end = start + count
        replacedStyles.clear()
        for (span in s.getSpans(start, end, Any::class.java)) {
            if (inlineOf(span).isNotEmpty() && s.getSpanStart(span) < end && s.getSpanEnd(span) > start) {
                replacedStyles += Triple(span, s.getSpanStart(span), s.getSpanEnd(span))
            }
        }
        for (marker in s.getSpans(start, end, MarkerSpan::class.java)) {
            val hidden = marker.hidden ?: continue
            val at = s.getSpanStart(marker)
            if (at < start || at >= end) continue
            // A deletion running past the heading's line takes the folded section
            // with it, since the heading is gone; only a backspace over the mark
            // itself gives the section back.
            if (end > lineEnd(s, at)) continue
            pendingRestore += start to hidden
            marker.hidden = null
        }
    }

    override fun onTextChanged(s: CharSequence, start: Int, before: Int, count: Int) {
        if (applying) return
        changeStart = start
        changeBefore = before
        changeCount = count
    }

    override fun afterTextChanged(e: Editable) {
        if (applying) return
        inTextChange = false
        edit {
            keepReplacedStyles(e)
            val inCode = markerAt(e, lineStart(e, changeStart))?.block?.type == BlockType.CODE
            if (changeCount > 0 && !inCode) for (style in typingStyles) extendStyle(e, style, changeStart, changeStart + changeCount)
            for ((at, hidden) in pendingRestore) e.insert(lineEnd(e, min(at, e.length)), hidden)
            pendingRestore.clear()
            // One character more than before, whether typed alone or committed
            // together with the word the keyboard was composing.
            val end = changeStart + changeCount
            if (changeCount - changeBefore == 1 && end in 1..e.length) {
                when (e[end - 1]) {
                    '\n' -> onEnter(e, end - 1)
                    ' ' -> onSpace(e, end)
                    '*', '_', '`' -> onInline(e, end)
                }
            }
            normalize(e)
        }
    }

    /**
     * The keyboard commits or corrects a word by replacing it, either at once or
     * as a deletion followed straight away by the new word, and either way the
     * spans that covered it are dropped. They are put back over the text that
     * took its place, so a styled word keeps its style, like typing over a
     * selection.
     */
    private fun keepReplacedStyles(e: Editable) {
        val now = SystemClock.uptimeMillis()
        if (deletedStyles.isNotEmpty() && changeBefore == 0 && changeStart == deletedAt && now - deletedTime < CORRECTION_WINDOW) {
            for ((span, start, end) in deletedStyles) {
                val to = changeStart + min(end, changeCount)
                if (changeStart + start < to) e.setSpan(span, changeStart + start, to, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        deletedStyles.clear()
        val replacedEnd = changeStart + changeBefore
        val delta = changeCount - changeBefore
        for ((span, start, end) in replacedStyles) {
            if (e.getSpanStart(span) >= 0) continue
            if (changeCount == 0) {
                deletedStyles += Triple(span, max(start, changeStart) - changeStart, min(end, replacedEnd) - changeStart)
                continue
            }
            val newStart = if (start <= changeStart) start else changeStart
            val newEnd = if (end >= replacedEnd) end + delta else changeStart + changeCount
            if (newStart < newEnd && newEnd <= e.length) e.setSpan(span, newStart, newEnd, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        if (deletedStyles.isNotEmpty()) {
            deletedAt = changeStart
            deletedTime = now
        }
        replacedStyles.clear()
    }

    /** `- `, `1. `, `[] `, `# ` and the rest, typed at the start of a line. */
    private fun onSpace(e: Editable, cursor: Int) {
        val ls = lineStart(e, cursor)
        val marker = markerAt(e, ls)
        val contentStart = if (marker != null) ls + 1 else ls
        if (ls == 0 || cursor <= contentStart || objectAt(e, ls) != null || marker?.block?.type == BlockType.CODE) return
        val prefix = e.substring(contentStart, cursor)
        val (block, length) = Markdown.detectBlockPrefix(prefix) ?: return
        if (length != prefix.length) return
        e.delete(contentStart, cursor)
        if (marker != null) {
            expand(e, marker)
            marker.block = block
        } else {
            e.insert(ls, MARK.toString())
            e.setSpan(MarkerSpan(block), ls, ls + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }

    private fun onEnter(e: Editable, newline: Int) {
        val ps = lineStart(e, newline)
        val marker = markerAt(e, ps)
        if (marker == null) {
            val row = Markdown.parseTableRow(e.substring(ps, newline))
            if (row != null && row.any { it.isNotBlank() }) {
                val table = MdTable(listOf(row, List(row.size) { "" }))
                e.replace(ps, newline, TABLE_CHAR.toString())
                e.setSpan(TableSpan(table, style, ::tableWidth), ps, ps + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            return
        }
        val type = marker.block.type
        if (type == BlockType.HEADING) return
        val itemWasEmpty = newline == ps + 1 && (newline + 1 == e.length || e[newline + 1] == '\n')
        if (itemWasEmpty) {
            // Enter on an empty item ends the list, the quote or the code block instead of adding another line to it.
            e.delete(newline, newline + 1)
            e.delete(ps, ps + 1)
        } else {
            val at = newline + 1
            e.insert(at, MARK.toString())
            e.setSpan(MarkerSpan(marker.block.copy(checked = false)), at, at + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }

    private fun onInline(e: Editable, cursor: Int) {
        val ls = lineStart(e, cursor)
        val marker = markerAt(e, ls)
        if (marker?.block?.type == BlockType.CODE) return
        val contentStart = if (marker != null) ls + 1 else ls
        // Three backticks alone at the start of a line open a code block.
        if (e.substring(contentStart, lineEnd(e, cursor)) == "```" && cursor == contentStart + 3) {
            e.delete(contentStart, cursor)
            if (marker != null) {
                expand(e, marker)
                marker.block = Block(BlockType.CODE)
            } else {
                e.insert(ls, MARK.toString())
                e.setSpan(MarkerSpan(Block(BlockType.CODE)), ls, ls + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            stripInline(e, ls)
            return
        }
        val line = e.substring(ls, lineEnd(e, cursor))
        val match = Markdown.findClosedInline(line, cursor - ls) ?: return
        val openStart = ls + match.openStart
        val closeStart = ls + match.closeStart
        val d = match.delimiter
        if (match.style != Inline.CODE && e.getSpans(openStart, closeStart + d, CodeSpan::class.java).isNotEmpty()) return
        e.delete(closeStart, closeStart + d)
        e.delete(openStart, openStart + d)
        e.setSpan(inlineSpan(match.style), openStart, closeStart - d, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    // endregion

    // region Taps

    private fun tap(x: Float, y: Float): Boolean {
        val layout = view.layout ?: return false
        val lx = x - view.totalPaddingLeft + view.scrollX
        val ly = (y - view.totalPaddingTop + view.scrollY).toInt()
        if (ly < 0 || ly > layout.height) return false
        val line = layout.getLineForVertical(ly)
        val offset = layout.getLineStart(line)
        val e = text
        tableAt(e, offset)?.let {
            onTableTap(it)
            return true
        }
        imageAt(e, offset)?.let { image ->
            bounds(image)?.let { onImageTap?.invoke(image, it) }
            return true
        }
        fileAt(e, offset)?.let { file ->
            if (!file.shown.isEmpty && ly >= file.shown.top && ly <= file.shown.bottom && lx <= file.shown.right) {
                onFileTap?.invoke(file, file.partAt(lx))
            }
            return true
        }
        if (lineStart(e, offset) != offset) return false
        val marker = markerAt(e, offset) ?: return false
        val codeView = marker.codeView
        if (codeView != null && e.getSpanStart(codeView) >= 0) {
            placeCaretInCode(e, offset, lx, codeView.scroll)
            return true
        }
        return when {
            marker.block.type == BlockType.HEADING && lx < style.gutter && offset > 0 -> {
                toggleCollapse(marker)
                true
            }
            marker.block.type == BlockType.CHECKBOX && lx >= style.gutter && lx < style.gutter + style.indent -> {
                marker.block = marker.block.copy(checked = !marker.block.checked)
                edit { normalize(text) }
                true
            }
            else -> false
        }
    }

    /**
     * A tap on a code block shown unwrapped puts the caret on the character
     * under the finger, which switches the block to editing, and wraps it.
     */
    private fun placeCaretInCode(e: Editable, lineStart: Int, lx: Float, scroll: CodeScroll) {
        val from = lineStart + 1
        val x = lx - style.gutter - style.cellPadding + scroll.x
        val count = if (x <= 0) 0 else codePaint().breakText(e, from, lineEnd(e, lineStart), true, x, null)
        view.requestFocus()
        view.setSelection(from + count)
        view.context.getSystemService(android.view.inputmethod.InputMethodManager::class.java)?.showSoftInput(view, 0)
    }

    private fun codePaint() = TextPaint(view.paint).also(::monospace)

    /** The code block shown unwrapped, or the table, under (x, y), with how far it can scroll. */
    private fun codeScrollAt(x: Float, y: Float): CodeScroll? {
        val layout = view.layout ?: return null
        val ly = (y - view.totalPaddingTop + view.scrollY).toInt()
        if (ly < 0 || ly > layout.height) return null
        val e = text
        val offset = layout.getLineStart(layout.getLineForVertical(ly))
        // A table works out how far it scrolls as it measures itself.
        tableAt(e, offset)?.let { return it.scroll }
        val codeView = markerAt(e, offset)?.codeView ?: return null
        if (e.getSpanStart(codeView) < 0) return null
        val scroll = codeView.scroll
        val paint = codePaint()
        var widest = 0f
        for (span in e.getSpans(0, e.length, CodeViewSpan::class.java)) {
            if (span.scroll === scroll) widest = max(widest, paint.measureText(e, e.getSpanStart(span), e.getSpanEnd(span)))
        }
        scroll.max = max(0, (widest - codeWidth()).toInt() + style.cellPadding)
        return scroll
    }

    /**
     * Setting the spans of the block or the table again is what gets them
     * redrawn at the new offset: the field keeps what it drew of its text and
     * would otherwise show it unchanged.
     */
    private fun codeScrolled(scroll: CodeScroll) {
        val e = text
        for (span in e.getSpans(0, e.length, TableSpan::class.java)) if (span.scroll === scroll) refresh(e, span)
        for (span in e.getSpans(0, e.length, CodeViewSpan::class.java)) if (span.scroll === scroll) refresh(e, span)
    }

    /**
     * Shows every code block unwrapped except the one the caret is in, which
     * wraps so that all of it can be seen while it is edited.
     */
    private fun updateCodeViews() {
        val was = applying
        applying = true
        try {
            val e = text
            val live = HashSet<CodeViewSpan>()
            val run = mutableListOf<Pair<Int, MarkerSpan>>()
            fun flush() {
                if (run.isEmpty()) return
                val runStart = run.first().first
                val runEnd = lineEnd(e, run.last().first)
                val scroll = run.first().second.codeScroll ?: CodeScroll()
                val editing = selStart <= runEnd && selEnd >= runStart
                for ((ls, marker) in run) {
                    marker.codeScroll = scroll
                    val le = lineEnd(e, ls)
                    if (editing || le <= ls + 1) continue
                    val span = marker.codeView ?: CodeViewSpan(style, ::codeWidth).also { marker.codeView = it }
                    span.scroll = scroll
                    if (e.getSpanStart(span) != ls + 1 || e.getSpanEnd(span) != le) {
                        e.setSpan(span, ls + 1, le, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    }
                    live += span
                }
                run.clear()
            }
            var start = 0
            while (start <= e.length) {
                val marker = markerAt(e, start)
                if (marker?.block?.type == BlockType.CODE) run += start to marker else flush()
                start = lineEnd(e, start) + 1
            }
            flush()
            for (span in e.getSpans(0, e.length, CodeViewSpan::class.java)) if (span !in live) e.removeSpan(span)
        } finally {
            applying = was
        }
    }

    private fun toggleCollapse(marker: MarkerSpan) = edit {
        val e = text
        if (e.getSpanStart(marker) < 0) return@edit
        if (marker.hidden != null) expand(e, marker) else collapse(e, marker)
        normalize(e)
        view.invalidate()
    }

    /**
     * Folds every heading when any is still open, inner ones included, so that
     * unfolding one heading later shows its subheadings folded; otherwise
     * unfolds them all, down to the headings that were folded inside others.
     */
    fun toggleAllHeadings() = edit {
        val e = text
        if (!allFolded(e)) {
            // From the last up: folding a heading only removes text below it.
            for (marker in foldTargets(e).asReversed()) if (marker.hidden == null) collapse(e, marker)
        } else {
            while (true) {
                val folded = headingMarkers(e).firstOrNull { it.hidden != null } ?: break
                expand(e, folded)
            }
        }
        normalize(e)
        view.invalidate()
    }

    private fun headingMarkers(e: Spanned): List<MarkerSpan> =
        lineStarts(e).mapNotNull { s -> markerAt(e, s)?.takeIf { it.block.type == BlockType.HEADING } }

    /**
     * The headings that folding everything folds: never the title, and of the
     * rest, a single top heading stays open, since folding it would leave
     * nothing but that heading.
     */
    private fun foldTargets(e: Spanned): List<MarkerSpan> {
        val headings = headingMarkers(e).filter { e.getSpanStart(it) > 0 }
        val top = headings.minOfOrNull { it.block.level } ?: return headings
        val roots = headings.filter { it.block.level == top }
        return if (roots.size == 1) headings - roots.first() else headings
    }

    private fun allFolded(e: Spanned) = foldTargets(e).let { it.isNotEmpty() && it.none { m -> m.hidden == null } }

    private fun collapse(e: Editable, marker: MarkerSpan) {
        val at = e.getSpanStart(marker)
        val end = lineEnd(e, at)
        val sectionEnd = sectionEndOffset(e, at)
        marker.hidden = copyContained(e, end, sectionEnd)
        e.delete(end, sectionEnd)
    }

    private fun expand(e: Editable, marker: MarkerSpan) {
        val hidden = marker.hidden ?: return
        marker.hidden = null
        e.insert(lineEnd(e, e.getSpanStart(marker)), hidden)
    }

    /** Where the section of the heading at [at] ends: before the next heading of its level or higher. */
    private fun sectionEndOffset(e: Spanned, at: Int): Int {
        val starts = lineStarts(e)
        val levels = starts.map { s -> markerAt(e, s)?.block?.takeIf { it.type == BlockType.HEADING }?.level ?: 0 }
        val end = Markdown.sectionEnd(levels, starts.indexOf(at))
        return if (end < starts.size) starts[end] - 1 else e.length
    }

    // endregion

    // region Keeping the spans in line with the text

    /**
     * Makes the spans agree with the text after any change: drops marks and
     * table characters that lost their span or ended up inside a line, keeps
     * each table on a line of its own, renumbers numbered lists and lays the
     * line spans over their lines again.
     */
    private fun normalize(e: Editable) {
        for (i in e.length - 1 downTo 0) {
            when (e[i]) {
                MARK -> {
                    val marker = markerAt(e, i)
                    if (marker == null || (i > 0 && e[i - 1] != '\n')) {
                        // A join of two lines carries the lower mark into the upper line.
                        marker?.let {
                            expand(e, it)
                            e.removeSpan(it)
                        }
                        e.delete(i, i + 1)
                    }
                }
                TABLE_CHAR -> if (objectAt(e, i) == null) e.delete(i, i + 1)
            }
        }
        for (span in e.getSpans(0, e.length, MarkerSpan::class.java)) {
            if (e.getSpanStart(span) == e.getSpanEnd(span)) e.removeSpan(span)
        }
        for (table in e.getSpans(0, e.length, ObjectSpan::class.java)) {
            val at = e.getSpanStart(table)
            if (at < 0 || e.getSpanEnd(table) == at) {
                e.removeSpan(table)
                continue
            }
            if (at + 1 < e.length && e[at + 1] != '\n') e.insert(at + 1, "\n")
            if (at > 0 && e[at - 1] != '\n') e.insert(at, "\n")
        }
        keepTitle(e)

        if (e.getSpanStart(gutter) != 0 || e.getSpanEnd(gutter) != e.length) {
            e.setSpan(gutter, 0, e.length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        }
        val live = HashSet<LineSpan>()
        var number = 0
        var start = 0
        while (start <= e.length) {
            val end = lineEnd(e, start)
            val marker = markerAt(e, start)
            if (marker == null) {
                number = 0
            } else {
                number = if (marker.block.type == BlockType.NUMBERED) number + 1 else 0
                val span = lineSpanFor(marker)
                val changed = marker.number != number || marker.drawn != marker.block
                marker.number = number
                marker.drawn = marker.block
                if (changed || e.getSpanStart(span) != start || e.getSpanEnd(span) != end) {
                    e.removeSpan(span)
                    e.setSpan(span, start, end, Spanned.SPAN_EXCLUSIVE_INCLUSIVE)
                }
                live += span
            }
            start = end + 1
        }
        for (span in e.getSpans(0, e.length, LineSpan::class.java)) if (span !in live) e.removeSpan(span)
    }

    /**
     * The first line is the note's title, as in Notes on the Mac: always an H1,
     * whatever was typed or pasted there, and it cannot be turned into anything
     * else, folded or moved.
     */
    private fun keepTitle(e: Editable) {
        if (objectAt(e, 0) != null) e.insert(0, "\n")
        val title = markerAt(e, 0)
        if (title == null) {
            e.insert(0, MARK.toString())
            e.setSpan(MarkerSpan(TITLE), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        } else if (title.block != TITLE) {
            expand(e, title)
            title.block = TITLE
        }
    }

    private fun lineSpanFor(marker: MarkerSpan): LineSpan {
        val kind = when (marker.block.type) {
            BlockType.HEADING -> HeadingLineSpan::class
            BlockType.CODE -> CodeLineSpan::class
            else -> ListLineSpan::class
        }
        marker.line?.let { if (it::class == kind) return it }
        val span = when (kind) {
            HeadingLineSpan::class -> HeadingLineSpan(marker, style)
            CodeLineSpan::class -> CodeLineSpan(style)
            else -> ListLineSpan(marker, style)
        }
        return span.also { marker.line = it }
    }

    /** Setting a span again is what makes the field measure and draw it anew. */
    private fun refresh(e: Editable, span: Any) {
        val start = e.getSpanStart(span)
        if (start < 0) return
        val end = e.getSpanEnd(span)
        val flags = e.getSpanFlags(span)
        e.removeSpan(span)
        e.setSpan(span, start, end, flags)
    }

    private fun refreshTables() = edit {
        val e = text
        e.getSpans(0, e.length, ObjectSpan::class.java).forEach { refresh(e, it) }
        e.getSpans(0, e.length, CodeViewSpan::class.java).forEach { refresh(e, it) }
    }

    private fun codeWidth() = tableWidth() - style.cellPadding

    private fun tableWidth(): Int {
        val width = if (view.width > 0) view.width else view.resources.displayMetrics.widthPixels
        return (width - view.totalPaddingLeft - view.totalPaddingRight - style.gutter - 1).coerceAtLeast(style.gutter)
    }

    // endregion

    // region Conversion

    private fun append(b: SpannableStringBuilder, line: MdLine) {
        val at = b.length
        if (line.block.type == BlockType.TABLE) {
            b.append(TABLE_CHAR)
            b.setSpan(TableSpan(line.table!!, style, ::tableWidth), at, at + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            return
        }
        if (line.block.type == BlockType.IMAGE) {
            b.append(TABLE_CHAR)
            b.setSpan(imageSpan(line.image!!), at, at + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            return
        }
        if (line.block.type == BlockType.FILE) {
            b.append(TABLE_CHAR)
            b.setSpan(fileSpan(line.file!!), at, at + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            return
        }
        if (line.block.type != BlockType.PARAGRAPH) {
            b.append(MARK)
            b.setSpan(MarkerSpan(line.block), at, at + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val from = b.length
        b.append(line.text)
        for (s in line.styles) b.setSpan(inlineSpan(s.style), from + s.start, from + s.end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    private fun linesOf(t: Spanned): List<MdLine> {
        val lines = mutableListOf<MdLine>()
        var start = 0
        while (start <= t.length) {
            val end = lineEnd(t, start)
            val table = tableAt(t, start)
            val picture = imageAt(t, start)
            val attached = fileAt(t, start)
            if (picture != null) {
                lines += MdLine(Block(BlockType.IMAGE), image = picture.image)
            } else if (attached != null) {
                lines += MdLine(Block(BlockType.FILE), file = attached.file)
            } else if (table != null) {
                lines += MdLine(Block(BlockType.TABLE), table = table.table)
            } else {
                val marker = markerAt(t, start)
                val from = if (marker != null) start + 1 else start
                lines += MdLine(marker?.block ?: Block(BlockType.PARAGRAPH), t.substring(from, end), stylesOf(t, from, end))
                // A folded section starts with the newline that ended the heading.
                marker?.hidden?.let { if (it.length > 1) lines += linesOf(it.subSequence(1, it.length) as Spanned) }
            }
            start = end + 1
        }
        return lines
    }

    private fun stylesOf(t: Spanned, from: Int, to: Int): List<InlineStyle> =
        t.getSpans(from, to, Any::class.java).flatMap { span ->
            val start = max(t.getSpanStart(span), from) - from
            val end = min(t.getSpanEnd(span), to) - from
            if (start >= end || t.getSpanFlags(span) and Spanned.SPAN_COMPOSING != 0) return@flatMap emptyList()
            inlineOf(span).map { InlineStyle(it, start, end) }
        }

    private fun inlineOf(span: Any): List<Inline> = when (span) {
        is StyleSpan -> when (span.style) {
            Typeface.BOLD -> listOf(Inline.BOLD)
            Typeface.ITALIC -> listOf(Inline.ITALIC)
            Typeface.BOLD_ITALIC -> listOf(Inline.BOLD, Inline.ITALIC)
            else -> emptyList()
        }
        is UnderlineSpan -> listOf(Inline.UNDERLINE)
        is CodeSpan -> listOf(Inline.CODE)
        else -> emptyList()
    }

    private fun inlineSpan(inline: Inline): Any = when (inline) {
        Inline.ITALIC -> StyleSpan(Typeface.ITALIC)
        Inline.BOLD -> StyleSpan(Typeface.BOLD)
        Inline.UNDERLINE -> UnderlineSpan()
        Inline.CODE -> CodeSpan(style.surface)
    }

    /** The text of [start, end) with only the spans that make up the note and lie wholly inside it. */
    private fun copyContained(src: Spanned, start: Int, end: Int): Spanned {
        val copy = SpannableStringBuilder(src.substring(start, end))
        for (span in src.getSpans(start, end, Any::class.java)) {
            if (span !is MarkerSpan && span !is ObjectSpan && inlineOf(span).isEmpty()) continue
            val flags = src.getSpanFlags(span)
            val s = src.getSpanStart(span)
            val en = src.getSpanEnd(span)
            if (flags and Spanned.SPAN_COMPOSING != 0 || s < start || en > end || s == en) continue
            copy.setSpan(span, s - start, en - start, flags)
        }
        return copy
    }

    // endregion

    /**
     * The editor changed the note by itself - a task ticked, a paragraph moved,
     * a table written back - or only redrew it; the screen tells which by
     * comparing the Markdown. Not called for a [quiet] redraw.
     */
    var onEdited: (() -> Unit)? = null

    private inline fun edit(quiet: Boolean = false, block: () -> Unit) {
        val was = applying
        applying = true
        try {
            block()
        } finally {
            applying = was
        }
        if (!was) {
            lastSelection = view.selectionStart to view.selectionEnd
            updateCodeViews()
            publishState()
            if (!quiet) onEdited?.invoke()
        }
    }

    private companion object {
        val TITLE = Block(BlockType.HEADING, level = 1)

        /** How soon after a deletion the keyboard's replacement for it arrives. */
        const val CORRECTION_WINDOW = 300L

        /** How long after a long press smart selection may still narrow the selection. */
        const val LIFTED_SELECTION_WINDOW = 1000L

        fun lineStart(t: CharSequence, at: Int) = if (at <= 0) 0 else t.lastIndexOf('\n', at - 1) + 1

        fun lineEnd(t: CharSequence, at: Int) = t.indexOf('\n', at).let { if (it < 0) t.length else it }

        fun lineStarts(t: CharSequence): List<Int> {
            val starts = mutableListOf(0)
            t.forEachIndexed { i, c -> if (c == '\n') starts += i + 1 }
            return starts
        }

        fun markerAt(t: Spanned, at: Int): MarkerSpan? =
            if (at < t.length && t[at] == MARK) {
                t.getSpans(at, at + 1, MarkerSpan::class.java).firstOrNull { t.getSpanStart(it) == at && t.getSpanEnd(it) == at + 1 }
            } else {
                null
            }

        fun objectAt(t: Spanned, at: Int): ObjectSpan? =
            if (at < t.length && t[at] == TABLE_CHAR) {
                t.getSpans(at, at + 1, ObjectSpan::class.java).firstOrNull { t.getSpanStart(it) == at }
            } else {
                null
            }

        fun imageAt(t: Spanned, at: Int): NoteImageSpan? = objectAt(t, at) as? NoteImageSpan

        fun fileAt(t: Spanned, at: Int): NoteFileSpan? = objectAt(t, at) as? NoteFileSpan

        fun tableAt(t: Spanned, at: Int): TableSpan? =
            if (at < t.length && t[at] == TABLE_CHAR) {
                t.getSpans(at, at + 1, TableSpan::class.java).firstOrNull { t.getSpanStart(it) == at }
            } else {
                null
            }
    }
}

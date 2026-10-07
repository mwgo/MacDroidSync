package pl.wojas.macdroidsync

/*
 * The Markdown the notes editor reads and writes, kept free of Android so the
 * rules can be tested on the JVM. The editor holds a note as spans; this is the
 * plain model it converts to and from.
 */

enum class BlockType { PARAGRAPH, BULLET, NUMBERED, CHECKBOX, QUOTE, HEADING, CODE, TABLE, IMAGE, FILE }

enum class Inline { ITALIC, BOLD, UNDERLINE, CODE }

/** [level] is a heading's; [depth] how far a list item is nested, 0 for the outermost. */
data class Block(val type: BlockType, val level: Int = 0, val checked: Boolean = false, val depth: Int = 0) {
    val isListItem: Boolean get() = type in LIST_ITEMS

    companion object {
        val LIST_ITEMS = setOf(BlockType.BULLET, BlockType.NUMBERED, BlockType.CHECKBOX)

        /** How deep lists nest, the outermost level not counted. */
        const val MAX_DEPTH = 5
    }
}

/** Counts the items of numbered lists, each level of a nested list on its own. */
class ListNumbers {
    private val counts = IntArray(Block.MAX_DEPTH + 1)

    /** The number of the line's item in its list, 0 for a line that is not a numbered item. */
    fun next(block: Block): Int {
        if (!block.isListItem) {
            counts.fill(0)
            return 0
        }
        val depth = block.depth.coerceIn(0, Block.MAX_DEPTH)
        for (d in depth + 1..Block.MAX_DEPTH) counts[d] = 0
        if (block.type != BlockType.NUMBERED) {
            counts[depth] = 0
            return 0
        }
        return ++counts[depth]
    }
}

/** A style over [start, end) of a line's text, with the delimiters already taken out. */
data class InlineStyle(val style: Inline, val start: Int, val end: Int)

/**
 * A table without a header: every row is alike. Markdown insists on one, so
 * the first row is written above the separator line and read back from there.
 */
data class MdTable(val rows: List<List<String>>) {
    val columns: Int get() = rows.maxOfOrNull { it.size } ?: 0
}

/** A picture on a line of its own: `![alt](path)`, the path relative to the note's folder. */
data class MdImage(val path: String, val alt: String = "")

/**
 * A file attached on a line of its own, a link into the notes' files folder:
 * `[name](files/…)`. [name] is what the tile shows; a recording is an audio file.
 */
data class MdFile(val path: String, val name: String) {
    val extension: String get() = path.substringAfterLast('/').substringAfterLast('.', "").lowercase()
    val isAudio: Boolean get() = extension in AUDIO

    companion object {
        const val FOLDER = "files/"

        /**
         * A new path for a file called [name], in a folder of its own so that it
         * keeps its name, without the characters a Markdown link cannot hold.
         */
        fun pathFor(name: String): String {
            val safe = name.replace(Regex("[\\s()\\[\\]/\\\\:*?\"<>|]+"), "_").trim('_').ifEmpty { "file" }
            return FOLDER + java.util.UUID.randomUUID() + "/" + safe
        }
        private val AUDIO = setOf("m4a", "mp3", "aac", "ogg", "oga", "opus", "wav", "amr", "flac", "3gp")
    }
}

data class MdLine(
    val block: Block,
    val text: String = "",
    val styles: List<InlineStyle> = emptyList(),
    val table: MdTable? = null,
    val image: MdImage? = null,
    val file: MdFile? = null,
)

/**
 * A pair of delimiters the character just typed has closed. Offsets are within
 * the line: the opening delimiter starts at [openStart], the closing one at
 * [closeStart], and both are [delimiter] characters long.
 */
data class InlineMatch(val style: Inline, val openStart: Int, val closeStart: Int, val delimiter: Int)

object Markdown {

    private val heading = Regex("^(#{1,6}) ")
    private val checkbox = Regex("^(?:[-*] )?\\[([ xX]?)] ")
    private val bullet = Regex("^[-*] ")
    private val numbered = Regex("^\\d+\\. ")
    private val quote = Regex("^>( |$)")
    /** What each level of a nested list is indented by, which suits both bullets and numbers. */
    private const val INDENT = "    "
    private val separatorCell = Regex("^:?-+:?$")
    private val image = Regex("^\\s*!\\[([^\\]]*)]\\(([^)\\s]+)\\)\\s*$")

    /** The picture a line consists of, or null when it is anything else. */
    fun parseImage(line: String): MdImage? =
        image.matchEntire(line)?.let { MdImage(path = it.groupValues[2], alt = it.groupValues[1]) }

    private val file = Regex("^\\s*\\[([^\\]]*)]\\((${Regex.escape(MdFile.FOLDER)}[^)\\s]+)\\)\\s*$")

    /** The attached file a line consists of; a link anywhere else is ordinary text. */
    fun parseFile(line: String): MdFile? =
        file.matchEntire(line)?.let { MdFile(path = it.groupValues[2], name = it.groupValues[1]) }

    fun fileToMarkdown(file: MdFile) = "[" + file.name.replace(Regex("[\\[\\]\\n]"), " ").trim() + "](" + file.path + ")"

    /** The paragraph mode a line starts with, and how many characters say so. */
    fun detectBlockPrefix(line: String): Pair<Block, Int>? {
        heading.find(line)?.let { return Block(BlockType.HEADING, level = it.groupValues[1].length) to it.value.length }
        checkbox.find(line)?.let { return Block(BlockType.CHECKBOX, checked = it.groupValues[1].isNotBlank()) to it.value.length }
        bullet.find(line)?.let { return Block(BlockType.BULLET) to it.value.length }
        numbered.find(line)?.let { return Block(BlockType.NUMBERED) to it.value.length }
        quote.find(line)?.let { return Block(BlockType.QUOTE) to it.value.length }
        return null
    }

    /** The cells of `| a | b |`, or null when the line is not a table row. */
    fun parseTableRow(line: String): List<String>? {
        val trimmed = line.trim()
        if (trimmed.length < 2 || !trimmed.startsWith('|') || !trimmed.endsWith('|')) return null
        return trimmed.substring(1, trimmed.length - 1).split('|').map { it.trim() }
    }

    fun isTableSeparator(line: String): Boolean =
        parseTableRow(line)?.all { separatorCell.matches(it) } == true

    /**
     * Whether the character before [cursor] closes `*x*`, `_x_`, `**x**`, `__x__`
     * or `` `x` ``. The text between may not be empty nor start or end with a
     * space, and a single delimiter never pairs with half of a double one, so
     * `**bold*` waits for its second star. Nothing is matched inside or across
     * code.
     */
    fun findClosedInline(line: String, cursor: Int): InlineMatch? {
        if (cursor < 1 || cursor > line.length) return null
        val c = line[cursor - 1]
        if (c == '`') {
            val open = line.lastIndexOf('`', cursor - 2)
            if (open < 0 || open == cursor - 2) return null
            return InlineMatch(Inline.CODE, open, cursor - 1, 1)
        }
        if (c != '*' && c != '_') return null
        val delimiter = if (cursor >= 2 && line[cursor - 2] == c) 2 else 1
        val closeStart = cursor - delimiter
        if (closeStart < 1 || line[closeStart - 1].isWhitespace() || line[closeStart - 1] == c) return null
        // An odd number of backticks before it means the text is still inside code.
        if (line.subSequence(0, closeStart).count { it == '`' } % 2 == 1) return null
        var j = closeStart - 1
        while (j >= 0) {
            val ch = line[j]
            if (ch == '`') return null
            if (ch != c) {
                j--
                continue
            }
            var runStart = j
            while (runStart > 0 && line[runStart - 1] == c) runStart--
            if (j - runStart + 1 == delimiter) {
                val contentStart = runStart + delimiter
                val wordBoundary = c != '_' || runStart == 0 || !line[runStart - 1].isLetterOrDigit()
                if (contentStart < closeStart && !line[contentStart].isWhitespace() && wordBoundary) {
                    return InlineMatch(styleOf(c, delimiter), runStart, closeStart, delimiter)
                }
            }
            j = runStart - 1
        }
        return null
    }

    /** A line's text with the inline delimiters taken out, and the styles they stood for. */
    fun parseInline(source: String): Pair<String, List<InlineStyle>> {
        val out = StringBuilder()
        val styles = mutableListOf<InlineStyle>()
        var i = 0
        while (i < source.length) {
            val c = source[i]
            if (c == '`') {
                val close = source.indexOf('`', i + 1)
                if (close > i + 1) {
                    styles += InlineStyle(Inline.CODE, out.length, out.length + close - i - 1)
                    out.append(source, i + 1, close)
                    i = close + 1
                    continue
                }
            } else if (c == '*' || c == '_') {
                val delimiter = if (source.startsWith("$c$c", i)) 2 else 1
                val close = findClose(source, i, c, delimiter)
                if (close >= 0) {
                    val (inner, innerStyles) = parseInline(source.substring(i + delimiter, close))
                    val start = out.length
                    out.append(inner)
                    innerStyles.forEach { styles += it.copy(start = it.start + start, end = it.end + start) }
                    styles += InlineStyle(styleOf(c, delimiter), start, out.length)
                    i = close + delimiter
                    continue
                }
            }
            out.append(c)
            i++
        }
        return out.toString() to styles
    }

    private fun findClose(s: String, open: Int, c: Char, delimiter: Int): Int {
        val from = open + delimiter
        if (from >= s.length || s[from].isWhitespace()) return -1
        if (c == '_' && open > 0 && s[open - 1].isLetterOrDigit()) return -1
        var j = from + 1
        while (j < s.length) {
            val ch = s[j]
            if (ch == '`') {
                val end = s.indexOf('`', j + 1)
                if (end > j + 1) {
                    j = end + 1
                    continue
                }
            }
            if (ch == c) {
                var run = 1
                while (j + run < s.length && s[j + run] == c) run++
                if (run == delimiter && !s[j - 1].isWhitespace()) return j
                j += run
                continue
            }
            j++
        }
        return -1
    }

    private fun styleOf(c: Char, delimiter: Int): Inline = when {
        delimiter == 1 -> Inline.ITALIC
        c == '*' -> Inline.BOLD
        else -> Inline.UNDERLINE
    }

    private fun delimiterOf(style: Inline): String = when (style) {
        Inline.ITALIC -> "*"
        Inline.BOLD -> "**"
        Inline.UNDERLINE -> "__"
        Inline.CODE -> "`"
    }

    /**
     * The first line after the heading at [index] that ends its section: the next
     * heading of the same or a higher level, or the end of the note. [levels]
     * holds each line's heading level, 0 for any other line.
     */
    fun sectionEnd(levels: List<Int>, index: Int): Int {
        val level = levels[index]
        for (i in index + 1 until levels.size) if (levels[i] in 1..level) return i
        return levels.size
    }

    /** Whether the line opens or closes a fenced code block. */
    fun isFence(line: String) = line.trimStart().startsWith("```")

    /** How many columns of indent [line] starts with, a tab counting as four. */
    private fun indentOf(line: String): Pair<Int, Int> {
        var columns = 0
        var chars = 0
        while (chars < line.length && (line[chars] == ' ' || line[chars] == '\t')) {
            columns += if (line[chars] == '\t') INDENT.length else 1
            chars++
        }
        return columns to chars
    }

    /**
     * How deep a list item indented by [columns] is, given the indents of the
     * items open above it, outermost first: deeper than the one above when it
     * is indented further, however far, and back at the level it lines up with
     * otherwise. A list's first item is its outermost level, however indented.
     */
    private fun depthOf(open: MutableList<Int>, columns: Int): Int {
        while (open.isNotEmpty() && open.last() > columns) open.removeAt(open.size - 1)
        if (open.isEmpty() || open.last() < columns) open += columns
        return (open.size - 1).coerceAtMost(Block.MAX_DEPTH)
    }

    fun parse(markdown: String): List<MdLine> {
        val source = markdown.replace("\r\n", "\n").split('\n')
        val lines = mutableListOf<MdLine>()
        val indents = mutableListOf<Int>()
        var i = 0
        while (i < source.size) {
            val line = source[i]
            val (columns, chars) = indentOf(line)
            val item = detectBlockPrefix(line.substring(chars))?.takeIf { it.first.isListItem }
            if (item != null) {
                val (text, styles) = parseInline(line.substring(chars + item.second))
                lines += MdLine(item.first.copy(depth = depthOf(indents, columns)), text, styles)
                i++
                continue
            }
            indents.clear()
            if (isFence(line)) {
                // The lines up to the closing fence, or to the end of a note that never closes it, as they are.
                val start = lines.size
                i++
                while (i < source.size && !isFence(source[i])) lines += MdLine(Block(BlockType.CODE), source[i++])
                if (lines.size == start) lines += MdLine(Block(BlockType.CODE))
                i++
                continue
            }
            val header = parseTableRow(line)
            if (header != null && i + 1 < source.size && isTableSeparator(source[i + 1])) {
                val rows = mutableListOf<List<String>>(header)
                i += 2
                while (i < source.size) {
                    val row = parseTableRow(source[i]) ?: break
                    rows += List(header.size) { row.getOrElse(it) { "" } }
                    i++
                }
                lines += MdLine(Block(BlockType.TABLE), table = MdTable(rows))
                continue
            }
            val picture = parseImage(line)
            if (picture != null) {
                lines += MdLine(Block(BlockType.IMAGE), image = picture)
                i++
                continue
            }
            val attached = parseFile(line)
            if (attached != null) {
                lines += MdLine(Block(BlockType.FILE), file = attached)
                i++
                continue
            }
            val prefix = detectBlockPrefix(line)
            val (text, styles) = parseInline(line.substring(prefix?.second ?: 0))
            lines += MdLine(prefix?.first ?: Block(BlockType.PARAGRAPH), text, styles)
            i++
        }
        return lines
    }

    fun toMarkdown(lines: List<MdLine>): String {
        val numbers = ListNumbers()
        return lines.mapIndexed { i, line ->
            val block = line.block
            val number = numbers.next(block)
            val indent = if (block.isListItem) INDENT.repeat(block.depth) else ""
            indent + when (block.type) {
                BlockType.CODE -> {
                    // A run of code lines shares one pair of fences.
                    val open = if (lines.getOrNull(i - 1)?.block?.type != BlockType.CODE) "```\n" else ""
                    val close = if (lines.getOrNull(i + 1)?.block?.type != BlockType.CODE) "\n```" else ""
                    open + line.text + close
                }
                BlockType.TABLE -> tableToMarkdown(line.table ?: MdTable(listOf(listOf(""))))
                BlockType.IMAGE -> line.image?.let { "![${it.alt}](${it.path})" } ?: ""
                BlockType.FILE -> line.file?.let { fileToMarkdown(it) } ?: ""
                BlockType.PARAGRAPH -> inlineToMarkdown(line.text, line.styles)
                BlockType.BULLET -> "- " + inlineToMarkdown(line.text, line.styles)
                BlockType.NUMBERED -> "$number. " + inlineToMarkdown(line.text, line.styles)
                BlockType.CHECKBOX -> (if (block.checked) "- [x] " else "- [ ] ") + inlineToMarkdown(line.text, line.styles)
                BlockType.QUOTE -> "> " + inlineToMarkdown(line.text, line.styles)
                BlockType.HEADING -> "#".repeat(block.level) + " " + inlineToMarkdown(line.text, line.styles)
            }
        }.joinToString("\n")
    }

    private fun tableToMarkdown(table: MdTable): String {
        fun row(cells: List<String>) = cells.joinToString(" | ", "| ", " |")
        val columns = table.columns.coerceAtLeast(1)
        val rows = table.rows.ifEmpty { listOf(emptyList()) }.map { r -> List(columns) { r.getOrElse(it) { "" } } }
        return (listOf(row(rows.first()), row(List(columns) { "---" })) + rows.drop(1).map(::row)).joinToString("\n")
    }

    /**
     * Puts the delimiters back. Styles that overlap without nesting are closed
     * and reopened around each other, so the result always parses again.
     */
    private fun inlineToMarkdown(text: String, styles: List<InlineStyle>): String {
        val spans = styles.filter { it.start < it.end }
            .sortedWith(compareBy<InlineStyle> { it.start }.thenByDescending { it.end })
        val out = StringBuilder()
        val open = mutableListOf<InlineStyle>()
        for (i in 0..text.length) {
            val closing = open.indexOfFirst { it.end <= i }
            if (closing >= 0) {
                val above = open.subList(closing, open.size).toList()
                above.asReversed().forEach { out.append(delimiterOf(it.style)) }
                repeat(above.size) { open.removeAt(open.size - 1) }
                above.filter { it.end > i }.forEach {
                    out.append(delimiterOf(it.style))
                    open += it
                }
            }
            spans.filter { it.start == i }.forEach {
                out.append(delimiterOf(it.style))
                open += it
            }
            if (i < text.length) out.append(text[i])
        }
        return out.toString()
    }
}

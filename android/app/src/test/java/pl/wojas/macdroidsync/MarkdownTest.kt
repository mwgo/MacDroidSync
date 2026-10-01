package pl.wojas.macdroidsync

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Markdown rules behind the notes editor. */
class MarkdownTest {

    @Test
    fun `line prefixes switch the paragraph mode`() {
        assertEquals(Block(BlockType.BULLET) to 2, Markdown.detectBlockPrefix("- "))
        assertEquals(Block(BlockType.BULLET) to 2, Markdown.detectBlockPrefix("* item"))
        assertEquals(Block(BlockType.NUMBERED) to 4, Markdown.detectBlockPrefix("12. "))
        assertEquals(Block(BlockType.CHECKBOX) to 3, Markdown.detectBlockPrefix("[] "))
        assertEquals(Block(BlockType.CHECKBOX) to 4, Markdown.detectBlockPrefix("[ ] "))
        assertEquals(Block(BlockType.CHECKBOX, checked = true) to 4, Markdown.detectBlockPrefix("[x] "))
        assertEquals(Block(BlockType.CHECKBOX) to 6, Markdown.detectBlockPrefix("- [ ] "))
        assertEquals(Block(BlockType.HEADING, level = 3) to 4, Markdown.detectBlockPrefix("### "))
        assertEquals(Block(BlockType.QUOTE) to 2, Markdown.detectBlockPrefix("> cytat"))
        assertEquals(Block(BlockType.QUOTE) to 1, Markdown.detectBlockPrefix(">"))
        assertNull(Markdown.detectBlockPrefix(">x"))
        assertNull(Markdown.detectBlockPrefix("####### "))
        assertNull(Markdown.detectBlockPrefix("-x"))
        assertNull(Markdown.detectBlockPrefix("#nope"))
        assertNull(Markdown.detectBlockPrefix("a - "))
    }

    @Test
    fun `closing delimiters are found as they are typed`() {
        assertEquals(InlineMatch(Inline.ITALIC, 3, 6, 1), Markdown.findClosedInline("to *it*", 7))
        assertEquals(InlineMatch(Inline.ITALIC, 0, 2, 1), Markdown.findClosedInline("_i_", 3))
        assertEquals(InlineMatch(Inline.BOLD, 0, 6, 2), Markdown.findClosedInline("**bold**", 8))
        assertEquals(InlineMatch(Inline.UNDERLINE, 1, 4, 2), Markdown.findClosedInline(" __u__", 6))
        assertEquals(InlineMatch(Inline.CODE, 0, 4, 1), Markdown.findClosedInline("`kod`", 5))
    }

    @Test
    fun `a half closed bold waits for its second star`() {
        assertNull(Markdown.findClosedInline("**bold*", 7))
        assertNull(Markdown.findClosedInline("__u_", 4))
    }

    @Test
    fun `delimiters around spaces or inside words leave the text alone`() {
        assertNull(Markdown.findClosedInline("a * nie *", 9))
        assertNull(Markdown.findClosedInline("a *nie *", 8))
        assertNull(Markdown.findClosedInline("snake_case_", 11))
        assertNull(Markdown.findClosedInline("``", 2))
        assertEquals("a * b *" to emptyList<InlineStyle>(), Markdown.parseInline("a * b *"))
    }

    @Test
    fun `code keeps its stars`() {
        assertEquals("a*b*c" to listOf(InlineStyle(Inline.CODE, 0, 5)), Markdown.parseInline("`a*b*c`"))
        assertNull(Markdown.findClosedInline("`a*b*", 5))
    }

    @Test
    fun `inline styles nest`() {
        val (text, styles) = Markdown.parseInline("**a _b_ c**")
        assertEquals("a b c", text)
        assertEquals(setOf(InlineStyle(Inline.ITALIC, 2, 3), InlineStyle(Inline.BOLD, 0, 5)), styles.toSet())
    }

    @Test
    fun `table rows and separators`() {
        assertEquals(listOf("A", "", "C"), Markdown.parseTableRow("| A |  | C |"))
        assertNull(Markdown.parseTableRow("a | b"))
        assertTrue(Markdown.isTableSeparator("|---|:--:|"))
        assertFalse(Markdown.isTableSeparator("| a |"))
    }

    @Test
    fun `a table is one line of the model`() {
        val lines = Markdown.parse("| A | B |\n|---|---|\n| 1 | 2 |\n| 3 |\nafter")
        assertEquals(2, lines.size)
        assertEquals(MdTable(listOf(listOf("A", "B"), listOf("1", "2"), listOf("3", ""))), lines[0].table)
        assertEquals("after", lines[1].text)
    }

    @Test
    fun `a table has no header of its own`() {
        val table = MdTable(listOf(listOf("a", "b"), listOf("c")))
        assertEquals("| a | b |\n| --- | --- |\n| c |  |", Markdown.toMarkdown(listOf(MdLine(Block(BlockType.TABLE), table = table))))
    }

    @Test
    fun `a picture is a line of its own`() {
        val lines = Markdown.parse("a\n![kot](images/k1.jpg)\n tekst ![x](y.jpg) dalej")
        assertEquals(MdImage("images/k1.jpg", "kot"), lines[1].image)
        assertEquals(BlockType.IMAGE, lines[1].block.type)
        assertEquals(BlockType.PARAGRAPH, lines[2].block.type)
        assertEquals("a\n![kot](images/k1.jpg)", Markdown.toMarkdown(lines.take(2)))
    }

    @Test
    fun `sections end at the next heading of the same or a higher level`() {
        val levels = listOf(1, 0, 2, 0, 3, 0, 2, 0, 1)
        assertEquals(8, Markdown.sectionEnd(levels, 0))
        assertEquals(6, Markdown.sectionEnd(levels, 2))
        assertEquals(6, Markdown.sectionEnd(levels, 4))
        assertEquals(9, Markdown.sectionEnd(levels, 8))
    }

    @Test
    fun `canonical markdown is written back unchanged`() {
        val source = listOf(
            "# T",
            "- a",
            "1. b",
            "2. c",
            "- [x] d",
            "- [ ] e",
            "> q *r*",
            "**f** *g* __h__ `i` **j *k* l**",
            "| A | B |",
            "| --- | --- |",
            "| 1 | 2 |",
            "",
        ).joinToString("\n")
        assertEquals(source, Markdown.toMarkdown(Markdown.parse(source)))
    }

    @Test
    fun `a fenced block keeps its lines as they are`() {
        val lines = Markdown.parse("a\n```kotlin\nval x = *y*\n\n- z\n```\nb")
        assertEquals(listOf("a", "val x = *y*", "", "- z", "b"), lines.map { it.text })
        assertEquals(
            listOf(BlockType.PARAGRAPH, BlockType.CODE, BlockType.CODE, BlockType.CODE, BlockType.PARAGRAPH),
            lines.map { it.block.type },
        )
        assertTrue(lines[1].styles.isEmpty())
        assertEquals("a\n```\nval x = *y*\n\n- z\n```\nb", Markdown.toMarkdown(lines))
    }

    @Test
    fun `an unclosed fence runs to the end and an empty one still makes a line`() {
        assertEquals(listOf("x", "y"), Markdown.parse("```\nx\ny").map { it.text })
        assertEquals(listOf(MdLine(Block(BlockType.CODE))), Markdown.parse("```\n```"))
    }

    @Test
    fun `the sample survives a round trip`() {
        val sample = File("src/main/res/raw/notes_sample.md").readText()
        val parsed = Markdown.parse(sample)
        assertEquals(parsed, Markdown.parse(Markdown.toMarkdown(parsed)))
        assertTrue(parsed.any { it.block.type == BlockType.TABLE })
    }

    @Test
    fun `a link into the notes' files is a file tile, any other link is text`() {
        val lines = Markdown.parse("# Pliki\n[Raport roczny.pdf](files/ab/Raport_roczny.pdf)\n[strona](https://example.com)")
        assertEquals(BlockType.FILE, lines[1].block.type)
        assertEquals(MdFile("files/ab/Raport_roczny.pdf", "Raport roczny.pdf"), lines[1].file)
        assertEquals(BlockType.PARAGRAPH, lines[2].block.type)
        assertEquals(lines, Markdown.parse(Markdown.toMarkdown(lines)))
    }

    @Test
    fun `a file path keeps the name without what a link cannot hold`() {
        val path = MdFile.pathFor("Nagranie (1) [x].m4a")
        assertTrue(path.startsWith(MdFile.FOLDER))
        assertTrue(path.endsWith("/Nagranie_1_x_.m4a"))
        assertTrue(MdFile(path, "n").isAudio)
        assertEquals(path, Markdown.parseFile("[n]($path)")?.path)
    }
}

package pl.wojas.macdroidsync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedNoteTest {

    @Test
    fun `the subject is the title and the text the body`() {
        val note = SharedNote.of("Artykuł", "https://example.com", emptyList())
        assertEquals("# Artykuł\nhttps://example.com", note.markdown)
        assertFalse(note.untitled)
    }

    @Test
    fun `a short first line of several is the title`() {
        val note = SharedNote.of(null, "Zakupy\nmleko\nchleb", emptyList())
        assertEquals("# Zakupy\nmleko\nchleb", note.markdown)
    }

    @Test
    fun `a single line stays in the body and leaves the title to write`() {
        val note = SharedNote.of(null, "Tylko jedno zdanie.", emptyList())
        assertTrue(note.untitled)
        val lines = Markdown.parse(note.markdown)
        assertEquals("", lines[0].text)
        assertEquals("Tylko jedno zdanie.", lines[1].text)
    }

    @Test
    fun `pictures follow the text, each on its own line`() {
        val note = SharedNote.of("Zdjęcia", null, listOf(MdImage("images/a.jpg"), MdImage("images/b.jpg")))
        val lines = Markdown.parse(note.markdown)
        assertEquals(listOf("images/a.jpg", "images/b.jpg"), lines.mapNotNull { it.image?.path })
        assertEquals("Zdjęcia", NoteSummary.of(note.markdown).title)
    }

    @Test
    fun `other files follow as tiles`() {
        val note = SharedNote.of("Umowa", null, emptyList(), listOf(MdFile("files/1/umowa.pdf", "umowa.pdf")))
        assertEquals("# Umowa\n[umowa.pdf](files/1/umowa.pdf)", note.markdown)
    }
}

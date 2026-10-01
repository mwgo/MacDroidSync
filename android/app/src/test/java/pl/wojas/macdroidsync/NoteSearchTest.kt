package pl.wojas.macdroidsync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Finding notes by their words. */
class NoteSearchTest {

    @Test
    fun `case and Polish marks do not count`() {
        assertEquals("zolw lodz", NoteSearch.fold("Żółw ŁÓDŹ"))
        assertTrue(NoteSearch.matches("Żółw w łodzi", NoteSearch.words("ZOLW lodz")))
    }

    @Test
    fun `folding keeps one character for one`() {
        val text = "Zażółć gęślą jaźń"
        assertEquals(text.length, NoteSearch.fold(text).length)
        assertEquals(listOf(7..11), NoteSearch.hits(text, NoteSearch.words("gesla")))
    }

    @Test
    fun `every word has to be there, in any order`() {
        val text = "Spotkanie w czwartek o 10"
        assertTrue(NoteSearch.matches(text, NoteSearch.words("czwartek spotkanie")))
        assertFalse(NoteSearch.matches(text, NoteSearch.words("czwartek piątek")))
        assertTrue(NoteSearch.matches(text, NoteSearch.words("   ")))
    }

    @Test
    fun `a snippet starts at a whole word before the first hit`() {
        val text = "Lista rzeczy do zabrania na wyjazd w góry: buty, kurtka, latarka i mapa."
        assertEquals("…w góry: buty, kurtka, latarka…", NoteSearch.snippet(text, NoteSearch.words("latarka"), before = 25, length = 30))
        assertNull(NoteSearch.snippet(text, NoteSearch.words("namiot")))
    }

    @Test
    fun `the text of a note is what it reads`() {
        assertEquals("Zakupy\n• mleko\n☑ chleb", NoteSummary.text("# Zakupy\n\n- mleko\n- [x] chleb"))
    }
}

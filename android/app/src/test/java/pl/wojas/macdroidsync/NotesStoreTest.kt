package pl.wojas.macdroidsync

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** The notes list: summaries, folders, pinning, sorting, copies and what stays on disk. */
class NotesStoreTest {

    @get:Rule
    val temp = TemporaryFolder()

    private var now = 1_000L
    private fun store() = NotesStore(temp.root) { now }

    @Test
    fun `a summary is the title, the start of the text and the first picture`() {
        val summary = NoteSummary.of("# Zakupy\n\n- mleko\n1. chleb\n- [x] jajka\n![](images/a.jpg)\n**Ważne** jutro")
        assertEquals("Zakupy", summary.title)
        assertEquals("• mleko\n1. chleb\n☑ jajka\nWażne jutro", summary.preview)
        assertEquals("images/a.jpg", summary.image)
    }

    @Test
    fun `the index survives a restart`() {
        val first = store()
        first.addFolder("Praca")
        val note = first.create("Praca", "# Plan\ntekst")
        first.setPinned(note.id, true)
        first.sort = NotesStore.Sort.NAME
        first.setCollapsed(NotesStore.PINNED, true)

        val again = store()
        assertEquals(listOf("Praca"), again.folders.map { it.name })
        assertEquals(NotesStore.Sort.NAME, again.sort)
        assertTrue(again.folder(NotesStore.PINNED)!!.collapsed)
        assertEquals(note.copy(pinned = true), again.note(note.id))
        assertEquals("# Plan\ntekst", again.read(note.id))
    }

    @Test
    fun `pinned notes come first and leave their folder`() {
        val s = store()
        s.addFolder("A")
        val a = s.create("A", "# a")
        val b = s.create("A", "# b")
        s.setPinned(b.id, true)
        val groups = s.groups()
        assertTrue(groups[0].isPinned)
        assertEquals(listOf(b.id), groups[0].notes.map { it.id })
        assertEquals(listOf(a.id), groups[1].notes.map { it.id })
    }

    @Test
    fun `without folders every note not pinned is in one group`() {
        val s = store()
        s.addFolder("A")
        s.addFolder("B")
        val a = s.create("A", "# a")
        val b = s.create("B", "# b")
        s.setPinned(a.id, true)
        val groups = s.groups(byFolder = false)
        assertEquals(2, groups.size)
        assertTrue(groups[0].isPinned)
        assertTrue(groups[1].isAll)
        assertEquals(listOf(b.id), groups[1].notes.map { it.id })
    }

    @Test
    fun `every folder sorts by name or by the last edit`() {
        val s = store()
        s.addFolder("A")
        val zebra = s.create("A", "# Zebra")
        now = 2_000
        val ala = s.create("A", "# ala")
        now = 3_000
        s.save(zebra.id, "# Zebra\nzmiana")
        assertEquals(listOf("Zebra", "ala"), s.groups()[0].notes.map { it.summary.title })
        s.sort = NotesStore.Sort.NAME
        assertEquals(listOf("ala", "Zebra"), s.groups()[0].notes.map { it.summary.title })
        assertEquals(ala.modified, s.note(ala.id)!!.modified)
    }

    @Test
    fun `saving the same text keeps the edit time`() {
        val s = store()
        val note = s.create("A", "# x")
        now = 9_000
        assertFalse(s.save(note.id, "# x"))
        assertEquals(1_000L, s.note(note.id)!!.modified)
    }

    @Test
    fun `a copy has pictures of its own`() {
        val s = store()
        File(temp.root, "images").mkdirs()
        File(temp.root, "images/p.png").writeText("png")
        File(temp.root, "images/p.json").writeText("strokes")
        val note = s.create("A", "# Rysunek\n![rysunek](images/p.png)")
        val copy = s.copy(note.id, " (kopia)")!!
        val text = s.read(copy.id)
        assertTrue(text.startsWith("# Rysunek (kopia)\n"))
        val path = Markdown.parseImage(text.lines()[1])!!.path
        assertTrue(path != "images/p.png")
        assertEquals("strokes", File(temp.root, path.removeSuffix(".png") + ".json").readText())

        s.deleteForever(note.id)
        assertFalse(File(temp.root, "images/p.png").exists())
        assertTrue(File(temp.root, path).exists())
        assertNull(s.note(note.id))
    }

    @Test
    fun `a copy has files of its own, and deleting a note takes its files`() {
        val s = store()
        File(temp.root, "files/1").mkdirs()
        File(temp.root, "files/1/umowa.pdf").writeText("pdf")
        val note = s.create("A", "# Umowa\n[umowa.pdf](files/1/umowa.pdf)")
        val copy = s.copy(note.id, " (kopia)")!!
        val file = Markdown.parseFile(s.read(copy.id).lines()[1])!!
        assertEquals("umowa.pdf", file.name)
        assertTrue(file.path != "files/1/umowa.pdf" && file.path.endsWith("/umowa.pdf"))
        assertEquals("pdf", File(temp.root, file.path).readText())

        s.deleteForever(note.id)
        assertFalse(File(temp.root, "files/1").exists())
        assertTrue(File(temp.root, file.path).exists())
    }

    @Test
    fun `a deleted note waits in the trash, and can come back`() {
        val s = store()
        val note = s.create("A", "# Notatka\ntekst")
        s.delete(note.id)
        assertTrue(s.notes.isEmpty())
        assertEquals(listOf(note.id), s.trashed.map { it.id })
        assertEquals(NotesStore.TRASH, s.groups().last().folder.name)
        assertFalse(s.save(note.id, "# Notatka\ninny"))

        assertEquals(now, store().note(note.id)!!.deleted)
        s.restore(note.id)
        assertEquals(listOf(note.id), s.notes.map { it.id })
        assertTrue(s.groups().none { it.isTrash })
    }

    @Test
    fun `the trash empties itself after thirty days`() {
        val s = store()
        val note = s.create("A", "# Stara")
        s.delete(note.id)
        now += NotesStore.TRASH_DAYS * 24 * 60 * 60 * 1000 + 1
        s.purge()
        assertNull(s.note(note.id))
        assertFalse(File(temp.root, note.id + ".md").exists())
    }

    @Test
    fun `a note that never had anything goes for good, one that had goes to the trash`() {
        val s = store()
        val empty = s.create("A", "")
        val written = s.create("A", "# Coś")
        s.discard(empty.id)
        s.discard(written.id)
        assertNull(s.note(empty.id))
        assertNotNull(s.note(written.id)!!.deleted)
    }

    @Test
    fun `a note from the Mac drops the pictures it no longer has and tells the screen`() {
        val s = store()
        File(temp.root, "images").mkdirs()
        val path = "images/00000000-0000-0000-0000-000000000001.png"
        File(temp.root, path).writeText("png")
        val note = s.create("A", "# Obraz\n![]($path)")
        var shown: String? = null
        s.attach(note.id, object : NotesStore.Editor {
            override val dirty = false
            override fun reload(markdown: String) { shown = markdown }
        })
        var changes = 0
        s.addListener { changes++ }
        s.saveFromSync(note.id, "B", "# Obraz\nbez obrazu")
        assertFalse(File(temp.root, path).exists())
        assertEquals("B", s.note(note.id)!!.folder)
        assertEquals("# Obraz\nbez obrazu", shown)
        assertTrue(changes > 0)
    }

    @Test
    fun `deleting a folder moves its notes to the first one left`() {
        val s = store()
        s.addFolder("A")
        s.addFolder("B")
        val note = s.create("B", "# b")
        assertTrue(s.deleteFolder("B"))
        assertEquals("A", s.note(note.id)!!.folder)
        assertFalse(s.deleteFolder("A"))
    }

    @Test
    fun `every folder folds at once`() {
        val s = store()
        s.addFolder("A")
        s.addFolder("B")
        s.setAllCollapsed(true)
        assertTrue(s.folders.all { it.collapsed } && s.folder(NotesStore.PINNED)!!.collapsed)
        s.setAllCollapsed(false)
        assertTrue(s.folders.none { it.collapsed })
    }

    @Test
    fun `renaming a folder takes its notes along`() {
        val s = store()
        s.addFolder("A")
        s.addFolder("B")
        val note = s.create("A", "# a")
        assertFalse(s.renameFolder("A", "B"))
        assertTrue(s.renameFolder("A", "C"))
        assertEquals("C", s.note(note.id)!!.folder)
    }
}

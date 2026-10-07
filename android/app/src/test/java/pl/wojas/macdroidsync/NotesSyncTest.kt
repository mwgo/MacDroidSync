package pl.wojas.macdroidsync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.MessageDigest

/** The phone's side of the notes sync: what it tells the Mac and what it accepts. */
class NotesSyncTest {

    @get:Rule
    val temp = TemporaryFolder()

    private var now = 1_000L
    private val store by lazy { NotesStore(temp.root) { now } }
    private val host by lazy { NotesHost(store) }

    private val image = "images/00000000-0000-0000-0000-000000000001.jpg"

    private fun refused(reason: String, block: () -> Unit) {
        try {
            block()
            fail("expected a refusal: $reason")
        } catch (e: NotesHost.Refused) {
            assertEquals(reason, e.reason)
        }
    }

    @Test
    fun `the payload goes over the wire and back`() {
        val payload = NotesPayload(
            requestId = "r1",
            notes = listOf(NoteEntry("a", "Dom", "Lista", 5, "h", deleted = true)),
            note = NoteDoc("a", "Dom", "# Lista", "h", listOf(NoteAsset(image, 3, "abc"))),
            baseHash = "b",
            offset = 7,
            total = 9,
        )
        val parsed = Message.parse(Message(type = MessageType.NOTES_GET, notes = payload).toBytes()).notes
        assertEquals(payload, parsed)
    }

    @Test
    fun `the manifest has the notes in use, the trash as deleted, and no empty note`() {
        val kept = store.create("Dom", "# Lista\n- mleko")
        store.create("Dom", "")
        val gone = store.create("Praca", "# Stara")
        store.delete(gone.id)
        val manifest = host.manifest()
        assertEquals(listOf("Dom", "Praca"), manifest.folders)
        val entries = manifest.notes!!.associateBy { it.id }
        assertEquals(2, entries.size)
        assertEquals("Lista", entries[kept.id]!!.title)
        assertNull(entries[kept.id]!!.deleted)
        assertEquals(true, entries[gone.id]!!.deleted)
    }

    @Test
    fun `the hash follows a picture whose path stays the same`() {
        File(temp.root, "images").mkdirs()
        File(temp.root, image).writeText("one")
        val note = store.create("Dom", "# Obraz\n![]($image)")
        val before = host.get(note.id).hash
        File(temp.root, image).writeText("turned")
        File(temp.root, image).setLastModified(System.currentTimeMillis() + 5000)
        assertNotEquals(before, host.get(note.id).hash)
        assertEquals(1, host.get(note.id).assets.size)
    }

    @Test
    fun `a note changed since the Mac last saw it is not overwritten`() {
        val note = store.create("Dom", "# A\nraz")
        val seen = host.get(note.id).hash
        store.save(note.id, "# A\ndwa")
        refused("changed") { host.put(note.id, "Dom", "# A\nz Maca", seen) }
        assertEquals("# A\ndwa", store.read(note.id))

        val fresh = host.get(note.id).hash
        val answer = host.put(note.id, "Dom", "# A\nz Maca", fresh)
        assertEquals("# A\nz Maca", store.read(note.id))
        assertEquals(host.get(note.id).hash, answer.hash)
    }

    @Test
    fun `a move from the Mac changes the folder and nothing else`() {
        val note = store.create("Dom", "# A\n- punkt")
        val before = host.get(note.id).hash
        val answer = host.move(note.id, "Praca")
        assertEquals("Praca", store.note(note.id)!!.folder)
        assertEquals("# A\n- punkt", store.read(note.id))
        assertEquals(before, answer.hash)
    }

    @Test
    fun `a note being edited is left alone`() {
        val note = store.create("Dom", "# A")
        store.attach(note.id, object : NotesStore.Editor {
            override val dirty = true
            override fun reload(markdown: String) = Unit
        })
        refused("editing") { host.put(note.id, "Dom", "# B", null) }
        refused("editing") { host.delete(note.id, null) }
    }

    @Test
    fun `a note referring to a file that has not arrived is refused`() {
        refused("missing asset") { host.put(null, "Dom", "# A\n![]($image)", null) }
    }

    @Test
    fun `a deletion from the Mac puts the note in the trash`() {
        val note = store.create("Dom", "# A")
        host.delete(note.id, host.get(note.id).hash)
        assertTrue(store.note(note.id)!!.deleted != null)
    }

    @Test
    fun `a conflict copy keeps the phone's version under another title`() {
        val note = store.create("Dom", "# Plan\ntreść")
        val copy = host.copy(note.id, " (Android)")
        assertEquals("# Plan (Android)\ntreść", store.read(copy.id!!))
    }

    @Test
    fun `only the notes' own places are accepted for a file`() {
        assertTrue(NotesRules.isAssetPath(image))
        assertTrue(NotesRules.isAssetPath("files/00000000-0000-0000-0000-000000000002/Umowa najmu.pdf"))
        assertFalse(NotesRules.isAssetPath("../index.json"))
        assertFalse(NotesRules.isAssetPath("images/../../x.jpg"))
        assertFalse(NotesRules.isAssetPath("files/00000000-0000-0000-0000-000000000002/a/b.pdf"))
        assertFalse(NotesRules.isAssetPath("abc.md"))
        refused("bad path") { host.writeAsset("../index.json", 0, 1, byteArrayOf(1), null) }
    }

    @Test
    fun `a file arrives in pieces and only takes its place once it is whole`() {
        val bytes = ByteArray(2_500_000) { (it % 251).toByte() }
        val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val chunk = NotesRules.ASSET_CHUNK_BYTES
        var offset = 0
        while (offset < bytes.size) {
            val end = minOf(offset + chunk, bytes.size)
            host.writeAsset(image, offset.toLong(), bytes.size.toLong(), bytes.copyOfRange(offset, end), sha)
            assertEquals(end == bytes.size, File(temp.root, image).exists())
            offset = end
        }
        val (first, total) = host.readAsset(image, 0)
        assertEquals(bytes.size.toLong(), total)
        assertEquals(chunk, first.size)
        val (last, _) = host.readAsset(image, 2L * chunk)
        assertEquals(bytes.size - 2 * chunk, last.size)
    }

    @Test
    fun `a file with the wrong checksum is thrown away`() {
        refused("checksum") { host.writeAsset(image, 0, 3, byteArrayOf(1, 2, 3), "00") }
        assertFalse(File(temp.root, image).exists())
        assertFalse(File(temp.root, "$image.part").exists())
    }

    @Test
    fun `a folder the Mac lost goes once only blank notes are left in it`() {
        store.addFolder("Dom")
        val note = store.create("Praca", "# A\ntekst")
        store.create("Praca", "")
        refused("not empty") { host.deleteFolder("Praca") }
        store.delete(note.id)
        host.deleteFolder("Praca")
        assertEquals(listOf("Dom"), store.folders.map { it.name })
        host.deleteFolder("Nie ma")
    }

    @Test
    fun `a note counts as synced while the Mac's hash for it holds`() {
        val a = store.create("Dom", "# A\nraz")
        val b = store.create("Dom", "# B\ndwa")
        assertFalse(store.isUnsynced(store.note(a.id)!!))
        host.synced(listOf(NoteEntry(a.id, "Dom", "", 0, host.get(a.id).hash), NoteEntry(b.id, "Dom", "", 0, "stary")))
        assertFalse(store.isUnsynced(store.note(a.id)!!))
        assertTrue(store.isUnsynced(store.note(b.id)!!))
        now += 10
        store.save(a.id, "# A\nzmiana")
        assertTrue(store.isUnsynced(store.note(a.id)!!))
        assertTrue(NotesStore(temp.root) { now }.isUnsynced(store.note(a.id)!!))
    }
}

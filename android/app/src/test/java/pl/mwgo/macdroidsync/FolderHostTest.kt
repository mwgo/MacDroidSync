package pl.mwgo.macdroidsync

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class FolderHostTest {

    private lateinit var storage: File
    private lateinit var host: FolderHost
    private var now = 1_760_000_000_000L
    private var access = true

    @Before
    fun setUp() {
        storage = Files.createTempDirectory("storage").toFile()
        host = FolderHost(storage, File(storage, "cache.json"), { access }, { now })
        val answers = host.configure(listOf(FolderPairConfig("p", "Documents/Notes MD")))
        assertEquals(true, answers.single().ok)
    }

    @After
    fun tearDown() {
        storage.deleteRecursively()
    }

    private val root get() = File(storage, "Documents/Notes MD")

    private fun refused(reason: String, block: () -> Unit) {
        try {
            block()
            fail("expected a refusal: $reason")
        } catch (refused: FolderHost.Refused) {
            assertEquals(reason, refused.reason)
        }
    }

    private fun put(path: String, text: String, baseHash: String? = null) {
        val bytes = text.toByteArray()
        host.write("p", path, 0, bytes.size.toLong(), bytes, FolderRules.sha256(bytes), baseHash)
    }

    @Test
    fun pathsOutsideTheStorageAreRefused() {
        val answers = host.configure(
            listOf(
                FolderPairConfig("a", "../x"),
                FolderPairConfig("b", "Android/data/x"),
                FolderPairConfig("c", "Documents/Ok"),
            )
        )
        assertEquals(listOf(false, false, true), answers.map { it.ok })
        access = false
        assertEquals("no access", host.configure(listOf(FolderPairConfig("d", "Documents/Ok"))).single().reason)
    }

    @Test
    fun manifestListsFilesAndFoldersButNotItsOwn() {
        File(root, "Work").mkdirs()
        File(root, "Work/a.md").writeText("a")
        File(root, ".DS_Store").writeText("x")
        File(root, ".macdroidsync/trash").mkdirs()
        val entries = host.manifest("p", null).entries!!
        assertEquals(listOf("Work", "Work/a.md"), entries.map { it.p })
        assertEquals(true, entries[0].d)
        assertEquals(FolderRules.sha256("a".toByteArray()), entries[1].h)
    }

    @Test
    fun manifestComesInPages() {
        repeat(FolderHost.PAGE + 3) { File(root, "f$it.txt").writeText("$it") }
        val first = host.manifest("p", null)
        assertEquals(FolderHost.PAGE, first.entries!!.size)
        val second = host.manifest("p", first.cursor)
        assertEquals(3, second.entries!!.size)
        assertNull(second.cursor)
    }

    @Test
    fun writeInPiecesChecksTheWholeAndTheBase() {
        val bytes = ByteArray(FolderRules.CHUNK + 10) { it.toByte() }
        val sha = FolderRules.sha256(bytes)
        host.write("p", "big.bin", 0, bytes.size.toLong(), bytes.copyOfRange(0, FolderRules.CHUNK), sha, null)
        assertFalse(File(root, "big.bin").exists())
        refused("bad offset") { host.write("p", "big.bin", 5, bytes.size.toLong(), ByteArray(1), sha, null) }
        host.write("p", "big.bin", 0, bytes.size.toLong(), bytes.copyOfRange(0, FolderRules.CHUNK), sha, null)
        host.write("p", "big.bin", FolderRules.CHUNK.toLong(), bytes.size.toLong(), bytes.copyOfRange(FolderRules.CHUNK, bytes.size), sha, null)
        assertTrue(File(root, "big.bin").readBytes().contentEquals(bytes))

        refused("changed") { put("big.bin", "new") }
        put("big.bin", "new", baseHash = sha)
        assertEquals("new", File(root, "big.bin").readText())
        refused("checksum") { host.write("p", "c.txt", 0, 1, "x".toByteArray(), "0".repeat(64), null) }
    }

    @Test
    fun readsInPieces() {
        put("a.md", "hello")
        val (bytes, total) = host.read("p", "a.md", 1)
        assertEquals("ello", String(bytes))
        assertEquals(5L, total)
        refused("missing") { host.read("p", "b.md", 0) }
        refused("bad path") { host.read("p", "../x", 0) }
    }

    @Test
    fun editingHoldsTheFileUntilSaved() {
        put("a.md", "one")
        val sha = FolderRules.sha256("one".toByteArray())
        host.setEditing(File(root, "a.md").absolutePath, true)
        refused("editing") { put("a.md", "two", sha) }
        refused("editing") { host.delete("p", "a.md", sha, false) }
        now += FolderHost.EDITING_TTL_MS + 1
        put("a.md", "two", sha)
        assertEquals("two", File(root, "a.md").readText())
    }

    @Test
    fun moveAndDeleteToTheTrash() {
        put("Notes/Old.md", "text")
        val sha = FolderRules.sha256("text".toByteArray())
        host.move("p", "Notes/Old.md", "Notes/New.md", sha)
        assertTrue(File(root, "Notes/New.md").exists())
        put("Notes/Other.md", "x")
        refused("exists") { host.move("p", "Notes/New.md", "Notes/Other.md", sha) }
        host.move("p", "Notes/New.md", "Notes/new.md", sha)
        assertEquals(listOf("Other.md", "new.md"), File(root, "Notes").list()!!.sorted())

        host.delete("p", "Notes/new.md", sha, false)
        assertFalse(File(root, "Notes/new.md").exists())
        assertEquals("text", File(root, ".macdroidsync/trash/20251009/Notes/new.md").readText())
        refused("not empty") { host.delete("p", "Notes", null, true) }
        host.delete("p", "Notes/Other.md", FolderRules.sha256("x".toByteArray()), false)
        host.delete("p", "Notes", null, true)
        assertFalse(File(root, "Notes").exists())
    }

    @Test
    fun theTrashEmptiesAfterThirtyDays() {
        put("a.md", "x")
        host.delete("p", "a.md", FolderRules.sha256("x".toByteArray()), false)
        now += 31L * 24 * 60 * 60 * 1000
        host.configure(listOf(FolderPairConfig("p", "Documents/Notes MD")))
        assertFalse(File(root, ".macdroidsync/trash/20251009").exists())
    }

    @Test
    fun ownWritesAreEchoesAndLocated() {
        put("a.md", "x")
        val path = File(root, "a.md").absolutePath
        assertTrue(host.isEcho(path))
        assertEquals("p" to "a.md", host.locate(path))
        assertEquals(listOf(path), host.takeWritten())
        now += FolderHost.ECHO_MS
        assertFalse(host.isEcho(path))
        assertNull(host.locate(File(storage, "Elsewhere/a.md").absolutePath))
    }
}

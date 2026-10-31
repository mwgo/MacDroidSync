package pl.mwgo.macdroidsync

import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The phone's side of the folder sync, see PROTOCOL.md section 10: it lists
 * the folders the Mac asked for, hands out and takes in files in pieces, and
 * moves and deletes them, every write only if the file is still what the Mac
 * last saw. The Mac decides everything; nothing here remembers a sync.
 *
 * [storage] is the root of the phone's shared storage, the paths of the pairs
 * are relative to it. Not thread safe: the service calls it one request at a time.
 */
class FolderHost(
    private val storage: File,
    private val cacheFile: File,
    private val hasAccess: () -> Boolean,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    class Refused(val reason: String) : Exception(reason)

    private data class Known(val size: Long, val modified: Long, val sha: String)

    /** The pairs the Mac described, by id: the ones the phone can use. */
    private var roots: Map<String, File> = emptyMap()
    private val checksums = HashMap<String, Known>()
    private var checksumsLoaded = false
    private var checksumsDirty = false
    /** Open files with changes not yet saved, by absolute path, until when. */
    private val editing = HashMap<String, Long>()
    /** What a request wrote, to tell the notes apps and to keep it from echoing back. */
    private val written = HashMap<String, Long>()

    val pairs: Map<String, File> get() = roots
    private var requested: List<FolderPairConfig> = emptyList()

    /** The answers again when a pair refused before can be used now, else null. */
    fun recheck(): List<FolderPairConfig>? {
        if (requested.all { roots.containsKey(it.id) }) return null
        val before = roots.keys.toSet()
        val answers = configure(requested)
        return answers.takeIf { roots.keys != before }
    }

    /** Takes the Mac's pairs and says of each whether this phone can use it. */
    fun configure(pairs: List<FolderPairConfig>): List<FolderPairConfig> {
        requested = pairs
        val usable = HashMap<String, File>()
        val answers = pairs.map { pair ->
            val reason = check(pair)
            if (reason == null) usable[pair.id] = File(storage, pair.path!!)
            FolderPairConfig(pair.id, ok = reason == null, reason = reason)
        }
        roots = usable
        usable.values.forEach { purgeTrash(it) }
        return answers
    }

    private fun check(pair: FolderPairConfig): String? {
        val path = pair.path?.trim('/') ?: return "bad path"
        if (!FolderRules.isValid(path) || path.split('/').first().equals("Android", ignoreCase = true)) return "bad path"
        if (!hasAccess()) return "no access"
        val root = File(storage, path)
        if (!root.canonicalPath.startsWith(storage.canonicalPath + File.separator)) return "bad path"
        if (!root.isDirectory && !root.mkdirs()) return "no access"
        return null
    }

    fun root(pair: String?): File = roots[pair ?: throw Refused("missing")] ?: throw Refused("off")

    // region Looking

    /** Everything in the folder, a page at a time. */
    fun manifest(pair: String?, cursor: Int?): FolderPayload {
        val root = root(pair)
        loadChecksums()
        val entries = ArrayList<FolderEntry>()
        walk(root, "", entries)
        saveChecksums()
        val from = (cursor ?: 0).coerceAtLeast(0)
        val to = minOf(entries.size, from + PAGE)
        return FolderPayload(
            pair = pair,
            entries = entries.subList(minOf(from, entries.size), to),
            cursor = if (to < entries.size) to else null,
        )
    }

    private fun walk(dir: File, prefix: String, out: MutableList<FolderEntry>) {
        val children = dir.listFiles() ?: return
        for (child in children.sortedBy { it.name }) {
            if (FolderRules.isExcluded(child.name)) continue
            val path = prefix + child.name
            if (!FolderRules.isValid(path)) continue
            if (child.isDirectory) {
                out += FolderEntry(p = path, m = child.lastModified(), d = true)
                walk(child, "$path/", out)
            } else if (child.isFile) {
                val size = child.length()
                // Too large to send: listed without a checksum would mean a change, so left out.
                val sha = if (size > FolderRules.MAX_FILE_SIZE) null else runCatching { checksum(child) }.getOrNull()
                out += FolderEntry(p = path, s = size, m = child.lastModified(), h = sha ?: "")
            }
        }
    }

    // endregion

    // region Reading and writing

    /** One piece of a file, and the file's size. */
    fun read(pair: String?, path: String?, offset: Long): Pair<ByteArray, Long> {
        val file = file(pair, path)
        if (!file.isFile) throw Refused("missing")
        RandomAccessFile(file, "r").use { raf ->
            val total = raf.length()
            if (offset < 0 || offset > total) throw Refused("bad offset")
            val size = minOf(FolderRules.CHUNK.toLong(), total - offset).toInt()
            val bytes = ByteArray(size)
            raf.seek(offset)
            raf.readFully(bytes)
            return bytes to total
        }
    }

    /**
     * Takes one piece of a file. The first piece checks that the file is still
     * [baseHash] (null for no file at all); the last checks the whole against
     * [sha256], and only then does it take the file's place.
     */
    fun write(pair: String?, path: String?, offset: Long, total: Long, data: ByteArray, sha256: String?, baseHash: String?) {
        val root = root(pair)
        val file = file(pair, path)
        if (total > FolderRules.MAX_FILE_SIZE) throw Refused("too big")
        if (isEditing(file)) throw Refused("editing")
        val part = partFile(root, path!!)
        if (offset == 0L) {
            guard(file, baseHash)
            part.parentFile?.mkdirs()
            part.delete()
        } else if (!part.exists() || part.length() != offset) {
            throw Refused("bad offset")
        }
        part.appendBytes(data)
        if (part.length() < total) return
        if (part.length() > total) {
            part.delete()
            throw Refused("bad offset")
        }
        val sha = FolderRules.sha256(part)
        if (sha256 != null && sha != sha256) {
            part.delete()
            throw Refused("checksum")
        }
        guard(file, baseHash)
        file.parentFile?.mkdirs()
        // The part's time, kept by the rename: an app saving the file right after gives it another one.
        val modified = part.lastModified()
        if (part.renameTo(file)) {
            remember(file, total, modified, sha)
        } else {
            part.copyTo(file, overwrite = true)
            part.delete()
        }
        wrote(file)
    }

    fun makeDirectory(pair: String?, path: String?) {
        val dir = file(pair, path)
        if (dir.isFile) throw Refused("exists")
        if (!dir.isDirectory && !dir.mkdirs()) throw Refused("no access")
        wrote(dir)
    }

    fun move(pair: String?, from: String?, to: String?, baseHash: String?) {
        val source = file(pair, from)
        val target = file(pair, to)
        if (!source.exists()) throw Refused("missing")
        if (isEditing(source)) throw Refused("editing")
        guard(source, baseHash)
        val sameFile = FolderRules.key(from!!) == FolderRules.key(to!!)
        if (target.exists() && !sameFile) throw Refused("exists")
        target.parentFile?.mkdirs()
        val moved = if (sameFile) {
            // Only the case differs, which the storage would take for the same name.
            val step = File(source.parentFile, ".${source.name}.${clock()}.move")
            source.renameTo(step) && step.renameTo(target)
        } else {
            source.renameTo(target)
        }
        if (!moved) throw Refused("no access")
        wrote(source)
        wrote(target)
    }

    /** Moves a file to the folder's trash, or removes an empty folder. */
    fun delete(pair: String?, path: String?, baseHash: String?, dir: Boolean) {
        val root = root(pair)
        val file = file(pair, path)
        if (!file.exists()) throw Refused("missing")
        if (dir) {
            if (!file.isDirectory) throw Refused("changed")
            val left = file.listFiles().orEmpty().filter { !FolderRules.isExcluded(it.name) }
            if (left.isNotEmpty()) throw Refused("not empty")
            file.listFiles().orEmpty().forEach { it.deleteRecursively() }
            if (!file.delete()) throw Refused("no access")
        } else {
            if (isEditing(file)) throw Refused("editing")
            guard(file, baseHash)
            val day = SimpleDateFormat("yyyyMMdd", Locale.ROOT).format(Date(clock()))
            var target = File(root, "${FolderRules.OWN_DIRECTORY}/trash/$day/$path")
            var n = 2
            while (target.exists()) target = File(root, "${FolderRules.OWN_DIRECTORY}/trash/$day/$path ${n++}")
            target.parentFile?.mkdirs()
            if (!file.renameTo(target)) throw Refused("no access")
        }
        wrote(file)
    }

    private fun guard(file: File, baseHash: String?) {
        when {
            baseHash == null && file.exists() -> throw Refused("changed")
            baseHash != null && !file.isFile -> throw Refused("missing")
            baseHash != null && checksum(file) != baseHash -> throw Refused("changed")
        }
    }

    private fun file(pair: String?, path: String?): File {
        val root = root(pair)
        if (path == null || !FolderRules.isValid(path)) throw Refused("bad path")
        return File(root, path)
    }

    private fun partFile(root: File, path: String) =
        File(root, "${FolderRules.OWN_DIRECTORY}/parts/${FolderRules.sha256(path.toByteArray())}.part")

    /** Deleted files older than thirty days go for good. */
    private fun purgeTrash(root: File) {
        val limit = clock() - TRASH_DAYS * 24 * 60 * 60 * 1000L
        val format = SimpleDateFormat("yyyyMMdd", Locale.ROOT)
        File(root, "${FolderRules.OWN_DIRECTORY}/trash").listFiles()?.forEach { day ->
            val date = runCatching { format.parse(day.name)?.time }.getOrNull() ?: return@forEach
            if (date < limit) day.deleteRecursively()
        }
    }

    // endregion

    // region Editing and echoes

    /** An app says a file is open with changes not yet saved, or no longer. */
    fun setEditing(path: String, dirty: Boolean) {
        val key = File(path).absolutePath
        if (dirty) editing[key] = clock() + EDITING_TTL_MS else editing.remove(key)
    }

    private fun isEditing(file: File): Boolean {
        val until = editing[file.absolutePath] ?: return false
        if (until > clock()) return true
        editing.remove(file.absolutePath)
        return false
    }

    private fun wrote(file: File) {
        written[file.absolutePath] = clock()
    }

    /** Whether a change seen in the folder is the sync's own, a moment ago. */
    fun isEcho(path: String): Boolean {
        val at = written[File(path).absolutePath] ?: return false
        return clock() - at < ECHO_MS
    }

    /** What the requests since the last call wrote, absolute paths. */
    fun takeWritten(): List<String> {
        val now = clock()
        val recent = written.filterValues { now - it < ECHO_MS }.keys.toList()
        written.entries.removeAll { now - it.value >= ECHO_MS }
        return recent
    }

    /** The pair a path on the phone belongs to, and its path within it. */
    fun locate(path: String): Pair<String, String>? {
        val absolute = File(path).absolutePath
        for ((id, root) in roots) {
            val prefix = root.absolutePath + File.separator
            if (absolute == root.absolutePath) return id to ""
            if (absolute.startsWith(prefix)) return id to absolute.removePrefix(prefix)
        }
        return null
    }

    // endregion

    // region Checksums

    private fun checksum(file: File): String {
        val key = file.absolutePath
        val size = file.length()
        val modified = file.lastModified()
        val known = checksums[key]
        if (known != null && known.size == size && known.modified == modified) return known.sha
        val sha = FolderRules.sha256(file)
        // Saved again while it was read, the sum is of the older text and is not kept, or it would stand for the newer one.
        if (file.length() == size && file.lastModified() == modified) remember(file, size, modified, sha)
        return sha
    }

    private fun remember(file: File, size: Long, modified: Long, sha: String) {
        checksums[file.absolutePath] = Known(size, modified, sha)
        checksumsDirty = true
    }

    private fun loadChecksums() {
        if (checksumsLoaded) return
        checksumsLoaded = true
        val json = runCatching { JSONObject(cacheFile.readText()) }.getOrNull() ?: return
        for (key in json.keys()) {
            val item = json.optJSONObject(key) ?: continue
            checksums[key] = Known(item.optLong("s"), item.optLong("m"), item.optString("h"))
        }
    }

    private fun saveChecksums() {
        if (!checksumsDirty) return
        // Only files that are still there are kept.
        checksums.keys.removeAll { !File(it).isFile }
        val json = JSONObject()
        for ((key, known) in checksums) {
            json.put(key, JSONObject().put("s", known.size).put("m", known.modified).put("h", known.sha))
        }
        runCatching {
            val tmp = File(cacheFile.path + ".new")
            tmp.writeText(json.toString())
            tmp.renameTo(cacheFile)
        }
        checksumsDirty = false
    }

    // endregion

    companion object {
        /** Entries per manifest page, well within a frame. */
        const val PAGE = 4000
        const val TRASH_DAYS = 30
        /** How long an app's word that a file is being edited holds without being said again. */
        const val EDITING_TTL_MS = 60_000L
        const val ECHO_MS = 3_000L
    }
}

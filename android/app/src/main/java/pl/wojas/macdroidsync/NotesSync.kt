package pl.wojas.macdroidsync

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest

/** One note as the phone describes it to the Mac, see PROTOCOL.md section 10. */
data class NoteEntry(
    val id: String,
    val folder: String,
    val title: String,
    val modified: Long,
    val hash: String,
    /** Set for a note in the trash, which is how the Mac learns it was deleted. */
    val deleted: Boolean? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("folder", folder)
        put("title", title)
        put("modified", modified)
        put("hash", hash)
        deleted?.let { put("deleted", it) }
    }

    companion object {
        fun fromJson(json: JSONObject) = NoteEntry(
            id = json.optString("id"),
            folder = json.optString("folder"),
            title = json.optString("title"),
            modified = json.optLong("modified"),
            hash = json.optString("hash"),
            deleted = if (json.has("deleted")) json.optBoolean("deleted") else null,
        )
    }
}

/** A picture or a file of a note: its path under the notes folder, size and checksum. */
data class NoteAsset(val path: String, val size: Long, val sha256: String) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("path", path)
        put("size", size)
        put("sha256", sha256)
    }

    companion object {
        fun fromJson(json: JSONObject) = NoteAsset(json.optString("path"), json.optLong("size"), json.optString("sha256"))
    }
}

/** A whole note, as notes-get hands it to the Mac. */
data class NoteDoc(
    val id: String,
    val folder: String,
    val markdown: String,
    val hash: String,
    val assets: List<NoteAsset>,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("folder", folder)
        put("markdown", markdown)
        put("hash", hash)
        put("assets", JSONArray().apply { assets.forEach { put(it.toJson()) } })
    }

    companion object {
        fun fromJson(json: JSONObject) = NoteDoc(
            id = json.optString("id"),
            folder = json.optString("folder"),
            markdown = json.optString("markdown"),
            hash = json.optString("hash"),
            assets = json.optJSONArray("assets")?.let { a -> (0 until a.length()).map { NoteAsset.fromJson(a.getJSONObject(it)) } }.orEmpty(),
        )
    }
}

/**
 * The `notes` field of a message. Which fields are set depends on the type;
 * see the table in PROTOCOL.md section 10.
 */
data class NotesPayload(
    val requestId: String? = null,
    val enabled: Boolean? = null,
    val folders: List<String>? = null,
    val notes: List<NoteEntry>? = null,
    val note: NoteDoc? = null,
    val id: String? = null,
    val folder: String? = null,
    val markdown: String? = null,
    val baseHash: String? = null,
    val hash: String? = null,
    val titleSuffix: String? = null,
    val path: String? = null,
    val offset: Long? = null,
    val total: Long? = null,
    val sha256: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        requestId?.let { put("requestId", it) }
        enabled?.let { put("enabled", it) }
        folders?.let { put("folders", JSONArray(it)) }
        notes?.let { list -> put("notes", JSONArray().apply { list.forEach { put(it.toJson()) } }) }
        note?.let { put("note", it.toJson()) }
        id?.let { put("id", it) }
        folder?.let { put("folder", it) }
        markdown?.let { put("markdown", it) }
        baseHash?.let { put("baseHash", it) }
        hash?.let { put("hash", it) }
        titleSuffix?.let { put("titleSuffix", it) }
        path?.let { put("path", it) }
        offset?.let { put("offset", it) }
        total?.let { put("total", it) }
        sha256?.let { put("sha256", it) }
    }

    companion object {
        fun fromJson(json: JSONObject) = NotesPayload(
            requestId = json.text("requestId"),
            enabled = if (json.has("enabled")) json.optBoolean("enabled") else null,
            folders = json.optJSONArray("folders")?.let { a -> (0 until a.length()).map { a.optString(it) } },
            notes = json.optJSONArray("notes")?.let { a -> (0 until a.length()).map { NoteEntry.fromJson(a.getJSONObject(it)) } },
            note = json.optJSONObject("note")?.let { NoteDoc.fromJson(it) },
            id = json.text("id"),
            folder = json.text("folder"),
            markdown = json.text("markdown"),
            baseHash = json.text("baseHash"),
            hash = json.text("hash"),
            titleSuffix = json.text("titleSuffix"),
            path = json.text("path"),
            offset = if (json.has("offset")) json.optLong("offset") else null,
            total = if (json.has("total")) json.optLong("total") else null,
            sha256 = json.text("sha256"),
        )

        private fun JSONObject.text(key: String): String? = if (has(key) && !isNull(key)) optString(key) else null
    }
}

/** The rules of the notes sync that need no Android. */
object NotesRules {
    /** Raw bytes of one notes-asset chunk; base64 makes it a third bigger, well inside a frame. */
    const val ASSET_CHUNK_BYTES = 1024 * 1024

    /** The largest picture or file the sync carries, as the file transfer of section 5. */
    const val MAX_ASSET_BYTES = 512L * 1024 * 1024

    private val imagePath = Regex("^images/[0-9a-fA-F-]{36}\\.[A-Za-z0-9]{1,5}$")
    private val filePath = Regex("^files/[0-9a-fA-F-]{36}/[^/\\\\\\u0000-\\u001f]{1,200}$")

    /**
     * Whether [path] is where the notes keep a picture or a file. A path from
     * the Mac is untrusted: anything else, `..` included, is refused.
     */
    fun isAssetPath(path: String): Boolean =
        !path.contains("..") && (imagePath.matches(path) || filePath.matches(path))

    /**
     * What the Mac compares to tell a change: the text and every picture and
     * file, since a turned picture or a redrawn drawing keeps its path.
     */
    fun hash(markdown: String, assets: List<NoteAsset>): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(markdown.toByteArray(Charsets.UTF_8))
        for (asset in assets) digest.update("\n${asset.path}:${asset.sha256}".toByteArray(Charsets.UTF_8))
        return hex(digest.digest())
    }

    fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return hex(digest.digest())
    }

    fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

    /** Whether a note has nothing in it, so that there is nothing to give the Mac yet. */
    fun isBlank(markdown: String) = Markdown.parse(markdown).all {
        it.table == null && it.image == null && it.file == null && it.text.isBlank()
    }
}

/**
 * The phone's side of the notes sync: it describes the notes, hands them out
 * and takes in what the Mac sends, always against the shared [store]. The Mac
 * decides everything; nothing here keeps any state of the sync but the
 * checksums of the files, which are slow to work out again.
 */
class NotesHost(private val store: NotesStore) {

    /** A refusal the Mac reads: [reason] is a plain word, see PROTOCOL.md. */
    class Refused(val reason: String) : Exception(reason)

    private data class Known(val size: Long, val time: Long, val sha256: String)

    private val checksums = HashMap<String, Known>()

    fun manifest(): NotesPayload {
        val live = store.notes.mapNotNull { note ->
            val markdown = store.read(note.id)
            if (NotesRules.isBlank(markdown)) return@mapNotNull null
            NoteEntry(note.id, note.folder, note.summary.title, note.modified, hashOf(markdown))
        }
        val gone = store.trashed.map { NoteEntry(it.id, it.folder, it.summary.title, it.modified, "", deleted = true) }
        return NotesPayload(folders = store.folders.map { it.name }, notes = live + gone)
    }

    fun get(id: String): NoteDoc {
        val note = store.note(id)?.takeIf { it.deleted == null } ?: throw Refused("missing")
        val markdown = store.read(id)
        val assets = assetsOf(markdown)
        return NoteDoc(id, note.folder, markdown, NotesRules.hash(markdown, assets), assets)
    }

    /**
     * Writes a note from the Mac. [baseHash] is what the Mac last saw of it: a
     * note changed since, or being edited on this phone right now, is left as
     * it is, and the Mac tries again or calls it a conflict.
     */
    fun put(id: String?, folder: String, markdown: String, baseHash: String?): NotesPayload {
        val missing = store.assetsOf(markdown).firstOrNull { !store.assetFile(it).isFile }
        if (missing != null) throw Refused("missing asset")
        synchronized(store) {
            if (id != null) {
                val note = store.note(id) ?: throw Refused("missing")
                if (note.deleted != null) throw Refused("deleted")
                if (store.isEditing(id)) throw Refused("editing")
                if (baseHash != null && hashOf(store.read(id)) != baseHash) throw Refused("changed")
            }
            val saved = store.saveFromSync(id, folder, markdown) ?: throw Refused("missing")
            return NotesPayload(id = saved.id, hash = hashOf(markdown))
        }
    }

    /**
     * Moves a note the Mac moved, without touching its text: written again from
     * Notes, its pictures and files would end up where Notes keeps them.
     */
    fun move(id: String, folder: String): NotesPayload {
        val note = store.note(id)?.takeIf { it.deleted == null } ?: throw Refused("missing")
        if (folder.isBlank()) throw Refused("missing")
        if (store.folder(folder) == null) store.addFolder(folder)
        if (note.folder != folder) store.move(id, folder)
        return NotesPayload(id = id, hash = hashOf(store.read(id)))
    }

    fun delete(id: String, baseHash: String?) {
        synchronized(store) {
            val note = store.note(id) ?: return
            if (note.deleted != null) return
            if (store.isEditing(id)) throw Refused("editing")
            if (baseHash != null && hashOf(store.read(id)) != baseHash) throw Refused("changed")
            store.delete(id)
        }
    }

    /**
     * Removes a folder the Mac lost, once no note the Mac knows of is left in
     * it; a blank note there moves as with any deleted folder.
     */
    fun deleteFolder(name: String) {
        synchronized(store) {
            if (store.folder(name) == null) return
            if (store.notes.any { it.folder == name && !NotesRules.isBlank(store.read(it.id)) }) throw Refused("not empty")
            if (!store.deleteFolder(name)) throw Refused("last folder")
        }
    }

    /** Marks the notes the Mac holds as they are here: those whose hash it gave still matches. */
    fun synced(entries: List<NoteEntry>) {
        synchronized(store) {
            val ids = entries.filter { entry ->
                store.note(entry.id)?.let { it.deleted == null && hashOf(store.read(it.id)) == entry.hash } == true
            }
            store.markSynced(ids.map { it.id })
        }
    }

    fun copy(id: String, titleSuffix: String): NotesPayload {
        val copy = store.copy(id, titleSuffix) ?: throw Refused("missing")
        return NotesPayload(id = copy.id, hash = hashOf(store.read(copy.id)))
    }

    /** One piece of a picture or a file, from [offset]; the whole size comes with it. */
    fun readAsset(path: String, offset: Long): Pair<ByteArray, Long> {
        if (!NotesRules.isAssetPath(path)) throw Refused("bad path")
        val file = store.assetFile(path)
        if (!file.isFile) throw Refused("missing")
        val total = file.length()
        if (offset < 0 || offset > total) throw Refused("bad offset")
        val length = minOf(NotesRules.ASSET_CHUNK_BYTES.toLong(), total - offset).toInt()
        val bytes = ByteArray(length)
        RandomAccessFile(file, "r").use {
            it.seek(offset)
            it.readFully(bytes)
        }
        return bytes to total
    }

    /**
     * One piece of a picture or a file from the Mac. It is written aside and
     * only takes its place once the last piece is in and the checksum matches,
     * so a note never refers to half a file.
     */
    fun writeAsset(path: String, offset: Long, total: Long, bytes: ByteArray, sha256: String?) {
        if (!NotesRules.isAssetPath(path)) throw Refused("bad path")
        if (total < 0 || total > NotesRules.MAX_ASSET_BYTES) throw Refused("too big")
        val file = store.assetFile(path)
        val part = File(file.path + ".part")
        file.parentFile?.mkdirs()
        if (offset == 0L) part.delete()
        if (part.length() != offset) throw Refused("bad offset")
        part.appendBytes(bytes)
        if (part.length() < total) return
        if (part.length() != total || (sha256 != null && NotesRules.sha256(part) != sha256)) {
            part.delete()
            throw Refused("checksum")
        }
        file.delete()
        if (!part.renameTo(file)) throw Refused("could not store")
    }

    private fun hashOf(markdown: String) = NotesRules.hash(markdown, assetsOf(markdown))

    private fun assetsOf(markdown: String): List<NoteAsset> = store.assetsOf(markdown).mapNotNull { path ->
        val file = store.assetFile(path)
        if (!file.isFile) return@mapNotNull null
        NoteAsset(path, file.length(), checksum(path, file))
    }

    private fun checksum(path: String, file: File): String = synchronized(checksums) {
        val known = checksums[path]
        if (known != null && known.size == file.length() && known.time == file.lastModified()) return known.sha256
        NotesRules.sha256(file).also { checksums[path] = Known(file.length(), file.lastModified(), it) }
    }
}

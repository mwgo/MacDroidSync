package pl.wojas.macdroidsync

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.Collator
import java.util.Locale
import java.util.UUID

/**
 * The notes on disk: one Markdown file per note under [root], its pictures in
 * root/images, and index.json holding the folders and, for every note, its
 * folder, whether it is pinned, its times and the summary a tile shows, so
 * that the list never has to read the notes themselves.
 *
 * Folders are one level deep and kept in the order they were made. Pinned
 * notes leave their folder's list for the pinned group, which folds on its
 * own under the [PINNED] key. One [sort] orders the notes of every group.
 */
class NotesStore(private val root: File, private val clock: () -> Long = System::currentTimeMillis) {

    enum class Sort { NAME, MODIFIED }

    data class Folder(val name: String, val collapsed: Boolean = false)

    data class Note(
        val id: String,
        val folder: String,
        val pinned: Boolean,
        val created: Long,
        val modified: Long,
        val summary: NoteSummary,
    )

    /** One group of the list: a folder, or the pinned notes, with its notes in their order. */
    data class Group(val folder: Folder, val notes: List<Note>) {
        val isPinned get() = folder.name == PINNED

        /** The one group of every note not pinned, when the list is not split into folders. */
        val isAll get() = folder.name == ALL
    }

    private val indexFile = File(root, "index.json")
    private val folderList = mutableListOf<Folder>()
    private val noteList = mutableListOf<Note>()
    private var pinned = Folder(PINNED)

    private var order = Sort.MODIFIED

    /** How the notes of every folder are ordered. */
    var sort: Sort
        get() = order
        set(value) {
            order = value
            persist()
        }

    val folders: List<Folder> get() = folderList.toList()
    val notes: List<Note> get() = noteList.toList()

    /** True before anything was ever stored, which is when the first note is to be made. */
    val isNew get() = !indexFile.isFile

    init {
        load()
    }

    fun note(id: String) = noteList.firstOrNull { it.id == id }

    fun folder(name: String) = if (name == PINNED) pinned else folderList.firstOrNull { it.name == name }

    // region Folders

    fun addFolder(name: String): Boolean {
        val clean = name.trim()
        if (clean.isEmpty() || folder(clean) != null) return false
        folderList += Folder(clean)
        persist()
        return true
    }

    fun renameFolder(from: String, to: String): Boolean {
        val clean = to.trim()
        val index = folderList.indexOfFirst { it.name == from }
        if (index < 0 || clean.isEmpty() || (clean != from && folder(clean) != null)) return false
        folderList[index] = folderList[index].copy(name = clean)
        noteList.replaceAll { if (it.folder == from) it.copy(folder = clean) else it }
        persist()
        return true
    }

    /** Removes a folder, moving its notes to the first folder left. The last folder stays. */
    fun deleteFolder(name: String): Boolean {
        if (folderList.size < 2) return false
        val index = folderList.indexOfFirst { it.name == name }
        if (index < 0) return false
        folderList.removeAt(index)
        val into = folderList.first().name
        noteList.replaceAll { if (it.folder == name) it.copy(folder = into) else it }
        persist()
        return true
    }

    fun setCollapsed(name: String, collapsed: Boolean) = changeFolder(name) { it.copy(collapsed = collapsed) }

    /** Folds or unfolds every folder at once, the pinned group included. */
    fun setAllCollapsed(collapsed: Boolean) {
        pinned = pinned.copy(collapsed = collapsed)
        folderList.replaceAll { it.copy(collapsed = collapsed) }
        persist()
    }

    private fun changeFolder(name: String, change: (Folder) -> Folder) {
        if (name == PINNED) {
            pinned = change(pinned)
        } else {
            val index = folderList.indexOfFirst { it.name == name }
            if (index < 0) return
            folderList[index] = change(folderList[index])
        }
        persist()
    }

    // endregion

    // region Notes

    /** A new note in [folder], made if missing; [at] backdates it, as the sample notes are. */
    fun create(folder: String, markdown: String, at: Long = clock()): Note {
        if (folder != PINNED && folder(folder) == null) addFolder(folder)
        val now = at
        val note = Note(UUID.randomUUID().toString(), folder, pinned = false, created = now, modified = now, NoteSummary.of(markdown))
        noteFile(note.id).writeText(markdown)
        noteList += note
        persist()
        return note
    }

    fun read(id: String): String = noteFile(id).takeIf { it.isFile }?.readText().orEmpty()

    /** Writes the note, moving its edit time on only when it changed. */
    fun save(id: String, markdown: String): Boolean {
        val index = noteList.indexOfFirst { it.id == id }
        if (index < 0 || read(id) == markdown) return false
        noteFile(id).writeText(markdown)
        noteList[index] = noteList[index].copy(modified = clock(), summary = NoteSummary.of(markdown))
        persist()
        return true
    }

    fun setPinned(id: String, pinned: Boolean) = changeNote(id) { it.copy(pinned = pinned) }

    fun move(id: String, folder: String) {
        if (folder(folder) == null || folder == PINNED) return
        changeNote(id) { it.copy(folder = folder) }
    }

    /**
     * A copy of the note in its folder, not pinned, its title followed by
     * [titleSuffix]. Its pictures and files are copied too, so that either note can
     * change or drop them without touching the other.
     */
    fun copy(id: String, titleSuffix: String): Note? {
        val source = note(id) ?: return null
        val lines = read(id).split('\n').toMutableList()
        if (lines.isNotEmpty() && lines[0].isNotBlank()) lines[0] = lines[0].trimEnd() + titleSuffix
        val markdown = lines.joinToString("\n") { line ->
            Markdown.parseFile(line)?.let { file ->
                val copied = copyFile(file.path) ?: return@joinToString line
                return@joinToString line.replace("](${file.path})", "]($copied)")
            }
            val image = Markdown.parseImage(line) ?: return@joinToString line
            val copied = copyImage(image.path) ?: return@joinToString line
            line.replace("](${image.path})", "]($copied)")
        }
        return create(source.folder, markdown)
    }

    /** Removes the note, its pictures and its files. */
    fun delete(id: String) {
        for (line in read(id).split('\n')) {
            Markdown.parseImage(line)?.let { deleteImage(it.path) }
            Markdown.parseFile(line)?.let { deleteFile(it.path) }
        }
        noteFile(id).delete()
        noteList.removeAll { it.id == id }
        persist()
    }

    private fun changeNote(id: String, change: (Note) -> Note) {
        val index = noteList.indexOfFirst { it.id == id }
        if (index < 0) return
        noteList[index] = change(noteList[index])
        persist()
    }

    // endregion

    /**
     * The list as it is shown: the pinned notes first when there are any,
     * then every folder in order, or with [byFolder] off all the other notes
     * together in one group.
     */
    fun groups(byFolder: Boolean = true): List<Group> {
        val groups = mutableListOf<Group>()
        val pinnedNotes = noteList.filter { it.pinned }
        if (pinnedNotes.isNotEmpty()) groups += Group(pinned, sorted(pinnedNotes))
        if (!byFolder) {
            val rest = noteList.filter { !it.pinned }
            if (rest.isNotEmpty()) groups += Group(Folder(ALL), sorted(rest))
            return groups
        }
        for (folder in folderList) groups += Group(folder, sorted(noteList.filter { !it.pinned && it.folder == folder.name }))
        return groups
    }

    private fun sorted(notes: List<Note>): List<Note> = when (sort) {
        Sort.MODIFIED -> notes.sortedByDescending { it.modified }
        Sort.NAME -> {
            val collator = Collator.getInstance(Locale.forLanguageTag("pl"))
            notes.sortedWith { a, b -> collator.compare(a.summary.title, b.summary.title) }
        }
    }

    private fun noteFile(id: String) = File(root, "$id.md")

    // region Pictures

    /** Keeps a picture from elsewhere as a new picture of the notes; returns its path. */
    fun addImage(extension: String, write: (File) -> Unit): String {
        val path = "images/${UUID.randomUUID()}.$extension"
        val file = File(root, path)
        file.parentFile?.mkdirs()
        write(file)
        return path
    }

    /** Copies a picture, and the strokes of a drawing, to a new name; returns the new path. */
    private fun copyImage(path: String): String? {
        val file = File(root, path)
        if (!file.isFile) return null
        val copied = "images/${UUID.randomUUID()}.${file.extension}"
        file.copyTo(File(root, copied))
        strokes(path).takeIf { it.isFile }?.copyTo(strokes(copied))
        return copied
    }

    private fun deleteImage(path: String) {
        File(root, path).delete()
        strokes(path).delete()
    }

    private fun strokes(path: String) = File(root, path.substringBeforeLast('.') + ".json")

    // endregion

    // region Files

    private fun copyFile(path: String): String? {
        val file = File(root, path)
        if (!file.isFile) return null
        val copied = MdFile.pathFor(file.name)
        file.copyTo(File(root, copied))
        return copied
    }

    /** Removes an attached file with the folder it has to itself. */
    fun deleteFile(path: String) {
        val file = File(root, path)
        file.delete()
        file.parentFile?.takeIf { it.name != MdFile.FOLDER.trimEnd('/') }?.delete()
    }

    // endregion

    // region Index

    private fun load() {
        if (!indexFile.isFile) return
        val json = runCatching { JSONObject(indexFile.readText()) }.getOrNull() ?: return
        json.optJSONObject("pinned")?.let { pinned = folderOf(it).copy(name = PINNED) }
        runCatching { Sort.valueOf(json.optString("sort")) }.getOrNull()?.let { order = it }
        val folders = json.optJSONArray("folders") ?: JSONArray()
        for (i in 0 until folders.length()) folderList += folderOf(folders.getJSONObject(i))
        val notes = json.optJSONArray("notes") ?: JSONArray()
        for (i in 0 until notes.length()) {
            val n = notes.getJSONObject(i)
            noteList += Note(
                id = n.getString("id"),
                folder = n.getString("folder"),
                pinned = n.optBoolean("pinned"),
                created = n.optLong("created"),
                modified = n.optLong("modified"),
                summary = NoteSummary(n.optString("title"), n.optString("preview"), n.optString("image").ifEmpty { null }),
            )
        }
    }

    private fun folderOf(json: JSONObject) = Folder(
        name = json.optString("name"),
        collapsed = json.optBoolean("collapsed"),
    )

    private fun folderJson(folder: Folder) = JSONObject().apply {
        put("name", folder.name)
        put("collapsed", folder.collapsed)
    }

    private fun persist() {
        root.mkdirs()
        val json = JSONObject().apply {
            put("version", 1)
            put("sort", sort.name)
            put("pinned", folderJson(pinned))
            put("folders", JSONArray().apply { folderList.forEach { put(folderJson(it)) } })
            put("notes", JSONArray().apply {
                for (note in noteList) put(JSONObject().apply {
                    put("id", note.id)
                    put("folder", note.folder)
                    put("pinned", note.pinned)
                    put("created", note.created)
                    put("modified", note.modified)
                    put("title", note.summary.title)
                    put("preview", note.summary.preview)
                    note.summary.image?.let { put("image", it) }
                })
            })
        }
        // Written aside first, so that a crash halfway never leaves half an index.
        val next = File(root, "index.json.new")
        next.writeText(json.toString())
        next.renameTo(indexFile)
    }

    // endregion

    companion object {
        /** The key of the pinned group; no folder can have an empty name. */
        const val PINNED = ""

        /** The key of the group of all notes; no folder can be named with a control character. */
        const val ALL = "\u0001"
    }
}

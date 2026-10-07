package pl.wojas.macdroidsync

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.Collator
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The notes on disk: one Markdown file per note under [root], its pictures in
 * root/images, and index.json holding the folders and, for every note, its
 * folder, whether it is pinned, its times and the summary a tile shows, so
 * that the list never has to read the notes themselves.
 *
 * Folders are one level deep and kept in the order they were made. Pinned
 * notes leave their folder's list for the pinned group, which folds on its
 * own under the [PINNED] key. One [sort] orders the notes of every group.
 *
 * A deleted note goes to the trash first, kept with the time it was deleted
 * for [TRASH_DAYS]; that is also how the sync with the Mac learns of it.
 *
 * The screens and the sync with the Mac share one store, [shared], so that
 * none of them writes the index from an older copy of it. Every method takes
 * the store's lock, and every change is told to the [addListener] listeners.
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
        /** When the note went to the trash, or null for a note in use. */
        val deleted: Long? = null,
        /** The edit time the Mac last said it holds the note at, or null before it ever did. */
        val synced: Long? = null,
    ) {
        /** A note with nothing in it, which the Mac is never given. */
        val isBlank: Boolean get() = summary.title.isBlank() && summary.preview.isBlank() && summary.image == null
    }

    /** One group of the list: a folder, or the pinned notes, with its notes in their order. */
    data class Group(val folder: Folder, val notes: List<Note>) {
        val isPinned get() = folder.name == PINNED

        /** The one group of every note not pinned, when the list is not split into folders. */
        val isAll get() = folder.name == ALL

        val isTrash get() = folder.name == TRASH
    }

    private val indexFile = File(root, "index.json")
    private val folderList = mutableListOf<Folder>()
    private val noteList = mutableListOf<Note>()
    private var pinned = Folder(PINNED)
    private var trash = Folder(TRASH, collapsed = true)

    private var order = Sort.MODIFIED

    /** Whether the Mac ever said which notes it holds; until then no note counts as not synced. */
    var syncing = false
        private set

    /** A note edited since the Mac last held it, or one it never got. */
    fun isUnsynced(note: Note) = syncing && note.deleted == null && !note.isBlank && note.synced != note.modified

    /** Records that the Mac holds these notes as they are now. */
    @Synchronized
    fun markSynced(ids: Collection<String>) {
        var changed = !syncing
        syncing = true
        val wanted = ids.toSet()
        noteList.replaceAll { note ->
            if (note.id in wanted && note.synced != note.modified) {
                changed = true
                note.copy(synced = note.modified)
            } else {
                note
            }
        }
        if (changed) persist()
    }

    /** How the notes of every folder are ordered. */
    var sort: Sort
        get() = order
        set(value) {
            order = value
            persist()
        }

    val folders: List<Folder> get() = synchronized(this) { folderList.toList() }

    /** The notes in use, the trash left out. */
    val notes: List<Note> get() = synchronized(this) { noteList.filter { it.deleted == null } }

    val trashed: List<Note> get() = synchronized(this) { noteList.filter { it.deleted != null } }

    /**
     * The screen showing a note, so that a change from the Mac neither lands on
     * top of edits not saved yet nor leaves the screen showing the old text.
     */
    interface Editor {
        /** Whether the screen has changes it has not written here yet; read off the main thread. */
        val dirty: Boolean

        /** The note changed underneath the screen; called on any thread. */
        fun reload(markdown: String)
    }

    private val editors = ConcurrentHashMap<String, Editor>()
    private val listeners = CopyOnWriteArrayList<() -> Unit>()

    fun attach(id: String, editor: Editor) {
        editors[id] = editor
    }

    fun detach(id: String, editor: Editor) {
        editors.remove(id, editor)
    }

    fun isEditing(id: String) = editors[id]?.dirty == true

    /** Called after every change, on the thread that made it. */
    fun addListener(listener: () -> Unit) {
        listeners += listener
    }

    fun removeListener(listener: () -> Unit) {
        listeners -= listener
    }

    /** True before anything was ever stored, which is when the first note is to be made. */
    val isNew get() = !indexFile.isFile

    init {
        load()
    }

    /** The note in use or in the trash. */
    @Synchronized
    fun note(id: String) = noteList.firstOrNull { it.id == id }

    @Synchronized
    fun folder(name: String) = when (name) {
        PINNED -> pinned
        TRASH -> trash
        else -> folderList.firstOrNull { it.name == name }
    }

    // region Folders

    @Synchronized
    fun addFolder(name: String): Boolean {
        val clean = name.trim()
        if (clean.isEmpty() || folder(clean) != null) return false
        folderList += Folder(clean)
        persist()
        return true
    }

    @Synchronized
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
    @Synchronized
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

    @Synchronized
    fun setCollapsed(name: String, collapsed: Boolean) = changeFolder(name) { it.copy(collapsed = collapsed) }

    /** Folds or unfolds every folder at once, the pinned group included. */
    @Synchronized
    fun setAllCollapsed(collapsed: Boolean) {
        pinned = pinned.copy(collapsed = collapsed)
        trash = trash.copy(collapsed = collapsed)
        folderList.replaceAll { it.copy(collapsed = collapsed) }
        persist()
    }

    private fun changeFolder(name: String, change: (Folder) -> Folder) {
        if (name == PINNED) {
            pinned = change(pinned)
        } else if (name == TRASH) {
            trash = change(trash)
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
    @Synchronized
    fun create(folder: String, markdown: String, at: Long = clock()): Note {
        if (folder != PINNED && folder(folder) == null) addFolder(folder)
        val now = at
        val note = Note(UUID.randomUUID().toString(), folder, pinned = false, created = now, modified = now, NoteSummary.of(markdown))
        noteFile(note.id).writeText(markdown)
        noteList += note
        persist()
        return note
    }

    @Synchronized
    fun read(id: String): String = noteFile(id).takeIf { it.isFile }?.readText().orEmpty()

    /** Writes the note, moving its edit time on only when it changed. Not a note in the trash. */
    @Synchronized
    fun save(id: String, markdown: String): Boolean {
        val index = noteList.indexOfFirst { it.id == id }
        if (index < 0 || noteList[index].deleted != null || read(id) == markdown) return false
        noteFile(id).writeText(markdown)
        noteList[index] = noteList[index].copy(modified = clock(), summary = NoteSummary.of(markdown))
        persist()
        return true
    }

    @Synchronized
    fun setPinned(id: String, pinned: Boolean) = changeNote(id) { it.copy(pinned = pinned) }

    @Synchronized
    fun move(id: String, folder: String) {
        if (folder(folder) == null || folder == PINNED) return
        changeNote(id) { it.copy(folder = folder) }
    }

    /**
     * A copy of the note in its folder, not pinned, its title followed by
     * [titleSuffix]. Its pictures and files are copied too, so that either note can
     * change or drop them without touching the other.
     */
    @Synchronized
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

    /** Puts the note in the trash. */
    @Synchronized
    fun delete(id: String) = changeNote(id) { if (it.deleted == null) it.copy(deleted = clock()) else it }

    /** Takes the note out of the trash, as if it had just been written. */
    @Synchronized
    fun restore(id: String) = changeNote(id) { it.copy(deleted = null, modified = clock()) }

    /** Removes the note for good, its pictures and its files with it. */
    @Synchronized
    fun deleteForever(id: String) {
        deleteAssets(assetsOf(read(id)))
        noteFile(id).delete()
        noteList.removeAll { it.id == id }
        persist()
    }

    /**
     * A note left with nothing in it: one that never had anything goes for
     * good, as there is nothing to keep, and one that had goes to the trash.
     */
    @Synchronized
    fun discard(id: String) {
        if (isBlank(read(id))) deleteForever(id) else delete(id)
    }

    /** Empties the trash of what has been there for longer than [TRASH_DAYS]. */
    @Synchronized
    fun purge() {
        val limit = clock() - TRASH_DAYS * DAY
        noteList.filter { (it.deleted ?: Long.MAX_VALUE) < limit }.forEach { deleteForever(it.id) }
    }

    /**
     * Writes a note the Mac sent: its text and folder, a new one when [id] is
     * null. The pictures and files the new text no longer refers to are removed,
     * and the screen showing the note, if any, shows the new text.
     */
    @Synchronized
    fun saveFromSync(id: String?, folder: String, markdown: String): Note? {
        val into = folder.takeIf { it.isNotBlank() && it != PINNED && it != TRASH && it != ALL } ?: folderList.firstOrNull()?.name ?: return null
        if (folder(into) == null) addFolder(into)
        if (id == null) return create(into, markdown)
        val index = noteList.indexOfFirst { it.id == id }
        if (index < 0) return null
        val before = read(id)
        noteFile(id).writeText(markdown)
        noteList[index] = noteList[index].copy(folder = into, deleted = null, modified = clock(), summary = NoteSummary.of(markdown))
        deleteAssets(assetsOf(before) - assetsOf(markdown).toSet())
        persist()
        editors[id]?.reload(markdown)
        return noteList[index]
    }

    /** The pictures and files [markdown] refers to, in order. */
    fun assetsOf(markdown: String): List<String> = markdown.split('\n').mapNotNull { line ->
        Markdown.parseImage(line)?.path ?: Markdown.parseFile(line)?.path
    }.filter { !it.contains("..") && (it.startsWith("images/") || it.startsWith(MdFile.FOLDER)) }.distinct()

    fun assetFile(path: String) = File(root, path)

    private fun deleteAssets(paths: Collection<String>) {
        for (path in paths) if (path.startsWith(MdFile.FOLDER)) deleteFile(path) else deleteImage(path)
    }

    private fun isBlank(markdown: String) = Markdown.parse(markdown).all {
        it.table == null && it.image == null && it.file == null && it.text.isBlank()
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
    @Synchronized
    fun groups(byFolder: Boolean = true): List<Group> {
        val groups = mutableListOf<Group>()
        val live = noteList.filter { it.deleted == null }
        val pinnedNotes = live.filter { it.pinned }
        if (pinnedNotes.isNotEmpty()) groups += Group(pinned, sorted(pinnedNotes))
        if (!byFolder) {
            val rest = live.filter { !it.pinned }
            if (rest.isNotEmpty()) groups += Group(Folder(ALL), sorted(rest))
        } else {
            for (folder in folderList) groups += Group(folder, sorted(live.filter { !it.pinned && it.folder == folder.name }))
        }
        val trashed = noteList.filter { it.deleted != null }
        if (trashed.isNotEmpty()) groups += Group(trash, trashed.sortedByDescending { it.deleted })
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
    @Synchronized
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
    @Synchronized
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
        json.optJSONObject("trash")?.let { trash = folderOf(it).copy(name = TRASH) }
        runCatching { Sort.valueOf(json.optString("sort")) }.getOrNull()?.let { order = it }
        syncing = json.optBoolean("syncing")
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
                deleted = if (n.has("deleted")) n.optLong("deleted") else null,
                synced = if (n.has("synced")) n.optLong("synced") else null,
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
            if (syncing) put("syncing", true)
            put("pinned", folderJson(pinned))
            put("trash", folderJson(trash))
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
                    note.deleted?.let { put("deleted", it) }
                    note.synced?.let { put("synced", it) }
                })
            })
        }
        // Written aside first, so that a crash halfway never leaves half an index.
        val next = File(root, "index.json.new")
        next.writeText(json.toString())
        next.renameTo(indexFile)
        listeners.forEach { it() }
    }

    // endregion

    companion object {
        /** The key of the pinned group; no folder can have an empty name. */
        const val PINNED = ""

        /** The key of the group of all notes; no folder can be named with a control character. */
        const val ALL = "\u0001"

        /** The key of the trash. */
        const val TRASH = "\u0002"

        const val TRASH_DAYS = 30L
        private const val DAY = 24L * 60 * 60 * 1000

        @Volatile
        private var instance: NotesStore? = null

        /** The one store of the app's notes, shared by its screens and the sync with the Mac. */
        fun shared(context: Context): NotesStore = instance ?: synchronized(this) {
            instance ?: NotesStore(File(context.applicationContext.filesDir, "notes")).also {
                it.purge()
                instance = it
            }
        }
    }
}

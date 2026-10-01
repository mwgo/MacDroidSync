package pl.wojas.macdroidsync

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import android.util.LruCache
import android.view.DragEvent
import android.view.View
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.PopupMenu
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.core.graphics.ColorUtils
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import com.google.android.material.color.MaterialColors
import androidx.recyclerview.widget.GridLayoutManager
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import pl.wojas.macdroidsync.databinding.ActivityNotesListBinding
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/**
 * The notes, reached from the Notes launcher icon: one tile or one row of a
 * list per note, in folders that fold, the pinned notes first. The search
 * field looks through the whole text of every note. A tap opens a note in
 * [NotesActivity], and a note held can be dragged to another folder; the list
 * is read again whenever it comes back.
 */
class NotesListActivity : ScreenActivity() {

    private lateinit var binding: ActivityNotesListBinding
    private lateinit var store: NotesStore
    private lateinit var images: NoteImages
    private lateinit var adapter: NotesListAdapter

    private val thumbnails = LruCache<String, Bitmap>(THUMBNAILS)
    private val imageWork = Executors.newSingleThreadExecutor()
    private val locale = Locale.ENGLISH

    /** The whole text of every note, read once a search needs it, until the notes are read again. */
    private val texts = mutableMapOf<String, String>()

    /**
     * Back while searching puts the keyboard away first, leaving the results
     * to look through, and then clears the search.
     */
    private val clearSearchOnBack = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() {
            val keyboard = ViewCompat.getRootWindowInsets(binding.search)?.isVisible(WindowInsetsCompat.Type.ime()) == true
            if (!keyboard) binding.search.text = null
            binding.search.clearFocus()
            WindowCompat.getInsetsController(window, binding.search).hide(WindowInsetsCompat.Type.ime())
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        NotesTheme.apply(this)
        super.onCreate(savedInstanceState)
        binding = ActivityNotesListBinding.inflate(layoutInflater)
        setContentView(binding.root)
        keepClearOfStatusBar(binding.page)
        padFromInsets(binding.body)
        images = NoteImages(this)

        val labels = NotesListAdapter.Labels(
            pinned = getString(R.string.notes_pinned),
            trash = getString(R.string.notes_trash),
            all = getString(R.string.notes_all),
            untitled = getString(R.string.notes_untitled),
            highlight = ColorUtils.setAlphaComponent(
                MaterialColors.getColor(this, androidx.appcompat.R.attr.colorPrimary, 0), 0x55,
            ),
            edited = ::edited,
        )
        adapter = NotesListAdapter(labels, ::thumbnail, callbacks)
        adapter.asList = prefs().getBoolean(AS_LIST, false)
        showViewToggle()
        binding.list.layoutManager = GridLayoutManager(this, NotesListAdapter.COLUMNS).apply { spanSizeLookup = adapter.spans }
        binding.list.adapter = adapter
        binding.toolNewFolder.setOnClickListener { askFolderName(R.string.notes_new_folder, "") { store.addFolder(it) } }
        binding.toolNewNote.setOnClickListener { store.folders.firstOrNull()?.let { newNote(it.name) } }
        binding.toolSort.setOnClickListener {
            store.sort = if (store.sort == NotesStore.Sort.NAME) NotesStore.Sort.MODIFIED else NotesStore.Sort.NAME
            showSort()
            refresh()
        }
        // Whatever is rebuilt in the list, the focus stays with the page, not the search field.
        binding.page.requestFocus()
        binding.toolFoldFolders.setOnClickListener {
            store.setAllCollapsed(!allFolded())
            refresh()
        }
        binding.toolFolders.setOnClickListener {
            prefs().edit().putBoolean(BY_FOLDER, !byFolder()).apply()
            showFoldersToggle()
            refresh()
        }
        showFoldersToggle()
        binding.toolView.setOnClickListener {
            adapter.asList = !adapter.asList
            prefs().edit().putBoolean(AS_LIST, adapter.asList).apply()
            showViewToggle()
        }
        showThemeToggle()
        binding.toolTheme.setOnClickListener { NotesTheme.toggle(this) }
        onBackPressedDispatcher.addCallback(this, clearSearchOnBack)
        binding.search.doAfterTextChanged {
            val searching = !it.isNullOrBlank()
            binding.searchClear.isVisible = !it.isNullOrEmpty()
            clearSearchOnBack.isEnabled = !it.isNullOrEmpty()
            refresh()
            if (searching) binding.list.scrollToPosition(0)
        }
        binding.searchClear.setOnClickListener { binding.search.text = null }
        binding.list.setOnDragListener { _, event -> onDrag(event) }
    }

    // region Dragging a note to another folder

    private var dragY = -1f
    private val density get() = resources.displayMetrics.density

    /** Scrolls the list while a dragged note is held near its top or bottom edge. */
    private val dragScroll = object : Runnable {
        override fun run() {
            if (dragY < 0) return
            val edge = 72 * density
            val list = binding.list
            val dy = when {
                dragY < edge -> -(edge - dragY) / edge * 28 * density
                dragY > list.height - edge -> (dragY - list.height + edge) / edge * 28 * density
                else -> 0f
            }
            if (dy != 0f) {
                list.scrollBy(0, dy.toInt())
                adapter.dropTarget = targetAt(dragY)
            }
            list.postOnAnimation(this)
        }
    }

    private var dragged: String? = null

    private fun onDrag(event: DragEvent): Boolean {
        val id = event.localState as? String ?: return false
        when (event.action) {
            DragEvent.ACTION_DRAG_STARTED -> {
                dragged = id
                dragY = event.y
                binding.list.postOnAnimation(dragScroll)
            }
            DragEvent.ACTION_DRAG_LOCATION -> {
                dragY = event.y
                adapter.dropTarget = targetAt(event.y)
            }
            DragEvent.ACTION_DROP -> adapter.dropTarget?.let { drop(id, it) }
            DragEvent.ACTION_DRAG_EXITED -> adapter.dropTarget = null
            DragEvent.ACTION_DRAG_ENDED -> {
                dragY = -1f
                dragged = null
                adapter.dropTarget = null
                refresh()
            }
        }
        return true
    }

    /**
     * The group under [y], other than the one the dragged note is in: of the
     * row there, or of the nearest row above a gap between rows.
     */
    private fun targetAt(y: Float): String? {
        val list = binding.list
        val child = list.findChildViewUnder(list.width / 2f, y)
            ?: (0 until list.childCount).map(list::getChildAt).lastOrNull { it.top <= y }
            ?: return null
        val target = adapter.folderAt(list.getChildAdapterPosition(child)) ?: return null
        // The trash is not somewhere to drop a note; deleting asks first.
        return target.takeIf { it != NotesStore.TRASH && it != dragged?.let(::groupOf) }
    }

    /** The group a note is shown in now. */
    private fun groupOf(id: String): String? {
        val note = store.note(id) ?: return null
        return when {
            note.deleted != null -> NotesStore.TRASH
            note.pinned -> NotesStore.PINNED
            !byFolder() -> NotesStore.ALL
            else -> note.folder
        }
    }

    /**
     * Onto the pinned group a note is pinned; onto all the notes it is
     * unpinned; into a folder it moves there and is unpinned, as it would not
     * show in that folder otherwise.
     */
    private fun drop(id: String, target: String) {
        val note = store.note(id) ?: return
        when (target) {
            NotesStore.PINNED -> store.setPinned(id, true)
            NotesStore.ALL -> store.setPinned(id, false)
            else -> {
                if (note.pinned) store.setPinned(id, false)
                store.move(id, target)
                Toast.makeText(this, getString(R.string.note_moved, target), Toast.LENGTH_SHORT).show()
            }
        }
    }

    // endregion

    private fun prefs() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun byFolder() = prefs().getBoolean(BY_FOLDER, true)

    /** Whether every group that can fold is folded, the list's own groups being what counts. */
    private fun allFolded() = store.groups(byFolder()).filter { !it.isAll }.let { groups ->
        groups.isNotEmpty() && groups.all { it.folder.collapsed }
    }

    /** The button shows what it will do: unfold once everything is folded. */
    private fun showFoldToggle() {
        val folded = allFolded()
        binding.toolFoldFolders.setImageResource(if (folded) R.drawable.ic_tool_unfold else R.drawable.ic_tool_fold)
        val label = getString(if (folded) R.string.notes_unfold_folders else R.string.notes_fold_folders)
        binding.toolFoldFolders.contentDescription = label
        binding.toolFoldFolders.tooltipText = label
    }

    /** Lit while the notes are split into folders. */
    private fun showFoldersToggle() {
        val on = byFolder()
        binding.toolFolders.isSelected = on
        val label = getString(if (on) R.string.notes_folders_on else R.string.notes_folders_off)
        binding.toolFolders.contentDescription = label
        binding.toolFolders.tooltipText = label
    }

    /** The button shows the order the notes are in now. */
    private fun showSort() {
        val byName = store.sort == NotesStore.Sort.NAME
        binding.toolSort.setImageResource(if (byName) R.drawable.ic_sort_name else R.drawable.ic_sort_modified)
        val label = getString(if (byName) R.string.notes_sorted_name else R.string.notes_sorted_modified)
        binding.toolSort.contentDescription = label
        binding.toolSort.tooltipText = label
    }

    /** The button shows the view it switches to. */
    private fun showViewToggle() {
        val label = getString(if (adapter.asList) R.string.notes_view_grid else R.string.notes_view_list)
        binding.toolView.setImageResource(if (adapter.asList) R.drawable.ic_view_grid else R.drawable.ic_view_list)
        binding.toolView.contentDescription = label
        binding.toolView.tooltipText = label
    }

    /** The button shows the mode it switches to. */
    private fun showThemeToggle() {
        val dark = NotesTheme.isDark(this)
        val label = getString(if (dark) R.string.notes_theme_light else R.string.notes_theme_dark)
        binding.toolTheme.setImageResource(if (dark) R.drawable.ic_theme_light else R.drawable.ic_theme_dark)
        binding.toolTheme.contentDescription = label
        binding.toolTheme.tooltipText = label
    }

    /** A change from the Mac arrives on the sync's thread; the list shows it once it is back here. */
    private val storeChanged: () -> Unit = {
        runOnUiThread {
            texts.clear()
            thumbnails.evictAll()
            if (dragged == null) refresh()
        }
    }

    override fun onPause() {
        super.onPause()
        store.removeListener(storeChanged)
    }

    override fun onResume() {
        super.onResume()
        store = NotesStore.shared(this)
        store.addListener(storeChanged)
        if (store.isNew) {
            val folder = getString(R.string.notes_default_folder)
            store.addFolder(folder)
            store.create(folder, resources.openRawResource(R.raw.notes_sample).bufferedReader().use { it.readText() })
        }
        NoteSamples.addOnce(this, store)
        thumbnails.evictAll()
        texts.clear()
        showSort()
        refresh()
    }

    override fun onDestroy() {
        super.onDestroy()
        imageWork.shutdown()
    }

    /**
     * Shows every folder, or while searching only the notes whose text has
     * every word of the query, with the piece of text around the first word
     * for a note that has it past what its tile shows anyway.
     */
    private fun refresh() {
        // A recreated screen restores the query before onResume reads the notes, which then shows them.
        if (!::store.isInitialized) return
        showFoldToggle()
        val query = binding.search.text?.toString().orEmpty()
        val words = NoteSearch.words(query)
        if (words.isEmpty()) {
            binding.noResults.isVisible = false
            adapter.show(store.groups(byFolder()))
            return
        }
        val snippets = mutableMapOf<String, String>()
        val groups = store.groups(byFolder()).mapNotNull { group ->
            val found = group.notes.filter { note ->
                val text = texts.getOrPut(note.id) { NoteSummary.text(store.read(note.id)) }
                if (!NoteSearch.matches(text, words)) return@filter false
                val preview = note.summary.title + "\n" + note.summary.preview
                if (NoteSearch.hits(preview.take(SHOWN), words).isEmpty()) {
                    NoteSearch.snippet(text.substringAfter('\n'), words)?.let { snippets[note.id] = it }
                }
                true
            }
            if (found.isEmpty()) null else group.copy(notes = found)
        }
        binding.noResults.text = getString(R.string.notes_no_results, query.trim())
        binding.noResults.isVisible = groups.isEmpty()
        adapter.show(groups, words, snippets)
    }

    private val callbacks = object : NotesListAdapter.Callbacks {
        override fun open(note: NotesStore.Note) = openNote(note.id, new = false, search = binding.search.text?.toString().orEmpty())

        override fun toggle(folder: NotesStore.Folder) {
            store.setCollapsed(folder.name, !folder.collapsed)
            refresh()
        }


        override fun add(folder: NotesStore.Folder) = newNote(folder.name)

        override fun startDrag(note: NotesStore.Note, view: View) {
            view.startDragAndDrop(ClipData.newPlainText("note", note.id), View.DragShadowBuilder(view), note.id, 0)
            // What is left behind shows where the note came from.
            view.alpha = 0.35f
        }

        override fun folderMenu(folder: NotesStore.Folder, anchor: View) {
            PopupMenu(this@NotesListActivity, anchor).apply {
                menu.add(0, RENAME, 0, R.string.notes_rename_folder)
                menu.add(0, DELETE, 1, R.string.notes_delete_folder).isEnabled = store.folders.size > 1
                setOnMenuItemClickListener { item ->
                    when (item.itemId) {
                        RENAME -> askFolderName(R.string.notes_rename_folder, folder.name) { store.renameFolder(folder.name, it) }
                        DELETE -> confirmDeleteFolder(folder)
                    }
                    true
                }
                show()
            }
        }
    }

    private fun newNote(folder: String) {
        val note = store.create(folder, "")
        openNote(note.id, new = true)
    }

    private fun openNote(id: String, new: Boolean, search: String = "") {
        startActivity(
            Intent(this, NotesActivity::class.java)
                .putExtra(NotesActivity.EXTRA_NOTE_ID, id)
                .putExtra(NotesActivity.EXTRA_NEW, new)
                .putExtra(NotesActivity.EXTRA_SEARCH, search),
        )
    }

    /** Asks for a folder name, starting from [current]; [apply] says whether it could be used. */
    private fun askFolderName(title: Int, current: String, apply: (String) -> Boolean) {
        val padding = (20 * resources.displayMetrics.density).roundToInt()
        val field = EditText(this).apply {
            setText(current)
            setSelection(current.length)
            setHint(R.string.notes_folder_name)
            isSingleLine = true
        }
        val frame = FrameLayout(this).apply {
            setPadding(padding, padding / 2, padding, 0)
            addView(field)
        }
        MaterialAlertDialogBuilder(this)
            .setTitle(title)
            .setView(frame)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val name = field.text.toString().trim()
                if (name.isEmpty() || name == current) return@setPositiveButton
                if (apply(name)) refresh() else Toast.makeText(this, R.string.notes_folder_exists, Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
        field.requestFocus()
    }

    private fun confirmDeleteFolder(folder: NotesStore.Folder) {
        val into = store.folders.first { it.name != folder.name }.name
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.notes_delete_folder)
            .setMessage(getString(R.string.notes_delete_folder_message, folder.name, into))
            .setPositiveButton(R.string.action_delete) { _, _ ->
                store.deleteFolder(folder.name)
                refresh()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    /** A tile's picture, read off the main thread at about the width of a tile. */
    private fun thumbnail(path: String, into: (Bitmap?) -> Unit) {
        thumbnails.get(path)?.let { return into(it) }
        val width = resources.displayMetrics.widthPixels / NotesListAdapter.COLUMNS
        imageWork.execute {
            val bitmap = images.load(MdImage(path), width)
            runOnUiThread {
                bitmap?.let { thumbnails.put(path, it) }
                into(bitmap)
            }
        }
    }

    /** When a note was edited: the time today, "Yesterday", or the date. */
    private fun edited(time: Long): String {
        val then = Calendar.getInstance().apply { timeInMillis = time }
        val now = Calendar.getInstance()
        fun sameDay(a: Calendar, b: Calendar) = a.get(Calendar.YEAR) == b.get(Calendar.YEAR) && a.get(Calendar.DAY_OF_YEAR) == b.get(Calendar.DAY_OF_YEAR)
        val yesterday = (now.clone() as Calendar).apply { add(Calendar.DAY_OF_YEAR, -1) }
        val pattern = when {
            sameDay(then, now) -> "HH:mm"
            sameDay(then, yesterday) -> return getString(R.string.notes_yesterday)
            then.get(Calendar.YEAR) == now.get(Calendar.YEAR) -> "MMM d"
            else -> "MMM d, yyyy"
        }
        return SimpleDateFormat(pattern, locale).format(Date(time))
    }

    private companion object {
        const val RENAME = 1
        const val DELETE = 2
        const val THUMBNAILS = 24
        const val PREFS = "notes"
        const val AS_LIST = "asList"
        const val BY_FOLDER = "byFolder"

        /** About as much of a note's beginning as a tile or a row shows before its text is cut. */
        const val SHOWN = 140
    }
}

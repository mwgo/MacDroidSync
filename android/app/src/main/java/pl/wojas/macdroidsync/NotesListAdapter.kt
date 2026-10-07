package pl.wojas.macdroidsync

import android.graphics.Bitmap
import android.graphics.drawable.ColorDrawable
import android.view.HapticFeedbackConstants
import android.text.SpannableString
import android.text.SpannableStringBuilder
import android.text.style.ForegroundColorSpan
import android.text.Spanned
import android.text.style.BackgroundColorSpan
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import androidx.core.view.isVisible
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import pl.wojas.macdroidsync.databinding.ItemNoteFolderBinding
import pl.wojas.macdroidsync.databinding.ItemNoteRowBinding
import pl.wojas.macdroidsync.databinding.ItemNoteTileBinding

/**
 * The notes list: a header for every folder, and under each open one its
 * notes, as tiles two to a row or as rows of a list. While searching, the
 * words found are marked, and a note found deep in its text shows the piece
 * around the word instead of its beginning. Holding a note starts dragging it
 * to another folder, whose header [dropTarget] then lights up. The activity
 * does all the work behind the taps; this only shows what [show] is given.
 */
class NotesListAdapter(
    private val labels: Labels,
    private val thumbnail: (path: String, into: (Bitmap?) -> Unit) -> Unit,
    private val callbacks: Callbacks,
) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {

    /** The words the list shows, looked up once by the activity. */
    class Labels(
        val pinned: String,
        val all: String,
        val trash: String,
        val untitled: String,
        val highlight: Int,
        val edited: (Long) -> String,
        /** The dot before the title of a note the Mac does not hold as it is. */
        val unsyncedColor: Int,
        val isUnsynced: (NotesStore.Note) -> Boolean,
    )

    interface Callbacks {
        fun open(note: NotesStore.Note)
        fun toggle(folder: NotesStore.Folder)
        fun add(folder: NotesStore.Folder)
        fun folderMenu(folder: NotesStore.Folder, anchor: View)
        fun startDrag(note: NotesStore.Note, view: View)
    }

    private sealed interface Row {
        val folder: String

        data class Header(val group: NotesStore.Group) : Row {
            override val folder get() = group.folder.name
        }

        data class Note(val note: NotesStore.Note, override val folder: String) : Row
    }

    private var rows: List<Row> = emptyList()
    private var words: List<String> = emptyList()
    private var snippets: Map<String, String> = emptyMap()

    /** Rows of a list instead of tiles. */
    var asList = false
        set(value) {
            field = value
            notifyDataSetChanged()
        }

    /**
     * Shows [groups], each folded as it is unless [words] are searched for,
     * which opens them all. [snippets] replaces the beginning of a note found
     * further on in its text.
     */
    fun show(groups: List<NotesStore.Group>, words: List<String> = emptyList(), snippets: Map<String, String> = emptyMap()) {
        this.words = words
        this.snippets = snippets
        val searching = words.isNotEmpty()
        val old = rows
        val marksChanged = words != shownWords || snippets != shownSnippets
        shownWords = words
        shownSnippets = snippets
        rows = groups.flatMap { group ->
            listOf(Row.Header(group)) + if (group.folder.collapsed && !searching) emptyList() else group.notes.map { Row.Note(it, group.folder.name) }
        }
        // Only what changed is told, so the list animates it: a folder folding
        // takes its notes away while the folders below it slide up.
        DiffUtil.calculateDiff(object : DiffUtil.Callback() {
            override fun getOldListSize() = old.size
            override fun getNewListSize() = rows.size
            override fun areItemsTheSame(o: Int, n: Int) = key(old[o]) == key(rows[n])
            override fun areContentsTheSame(o: Int, n: Int) = !marksChanged && old[o] == rows[n]
            override fun getChangePayload(o: Int, n: Int): Any? {
                val before = old[o] as? Row.Header ?: return null
                val after = rows[n] as? Row.Header ?: return null
                return FOLD.takeIf { !marksChanged && before.group.copy(folder = after.group.folder) == after.group }
            }
        }).dispatchUpdatesTo(this)
    }

    private var shownWords: List<String> = emptyList()
    private var shownSnippets: Map<String, String> = emptyMap()

    private fun key(row: Row) = when (row) {
        is Row.Header -> "folder:" + row.folder
        is Row.Note -> "note:" + row.note.id
    }

    /** The group, by folder name, that the row at [position] belongs to. */
    fun folderAt(position: Int): String? = rows.getOrNull(position)?.folder

    /** The group whose header is lit as where a dragged note would go, if any. */
    var dropTarget: String? = null
        set(value) {
            if (field == value) return
            val old = field
            field = value
            rows.forEachIndexed { i, row -> if (row is Row.Header && (row.folder == old || row.folder == value)) notifyItemChanged(i, DROP) }
        }

    /** Headers take the whole row, and so do the rows of a list; tiles share it two by two. */
    val spans = object : GridLayoutManager.SpanSizeLookup() {
        override fun getSpanSize(position: Int) = if (rows[position] is Row.Header || asList) COLUMNS else 1
    }

    override fun getItemCount() = rows.size

    override fun getItemViewType(position: Int) = when {
        rows[position] is Row.Header -> HEADER
        asList -> LIST_ROW
        else -> TILE
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
        val inflater = LayoutInflater.from(parent.context)
        return when (viewType) {
            HEADER -> HeaderHolder(ItemNoteFolderBinding.inflate(inflater, parent, false))
            LIST_ROW -> ListRowHolder(ItemNoteRowBinding.inflate(inflater, parent, false))
            else -> TileHolder(ItemNoteTileBinding.inflate(inflater, parent, false))
        }
    }

    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
        when (val row = rows[position]) {
            is Row.Header -> (holder as HeaderHolder).bind(row.group, animate = false)
            is Row.Note -> (holder as NoteHolder).bind(row.note)
        }
    }

    /** A header folded or lit as a drop target changes in place, without the list's cross fade. */
    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int, payloads: MutableList<Any>) {
        val row = rows[position]
        if (payloads.isEmpty() || row !is Row.Header) return onBindViewHolder(holder, position)
        (holder as HeaderHolder).bind(row.group, animate = FOLD in payloads)
    }

    /** [text] with every word searched for marked. */
    private fun marked(text: String): CharSequence {
        if (words.isEmpty()) return text
        val hits = NoteSearch.hits(text, words)
        if (hits.isEmpty()) return text
        return SpannableString(text).apply {
            for (hit in hits) setSpan(BackgroundColorSpan(labels.highlight), hit.first, hit.last + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }

    private inner class HeaderHolder(private val b: ItemNoteFolderBinding) : RecyclerView.ViewHolder(b.root) {
        fun bind(group: NotesStore.Group, animate: Boolean) {
            val folder = group.folder
            val searching = words.isNotEmpty()
            b.name.text = when {
                group.isPinned -> labels.pinned
                group.isAll -> labels.all
                group.isTrash -> labels.trash
                else -> folder.name
            }
            // All the notes together fold no more than a folder of one note would help.
            b.chevron.isVisible = !group.isAll
            b.count.text = group.notes.size.toString()
            val rotation = if (folder.collapsed && !searching) -90f else 0f
            if (animate) b.chevron.animate().rotation(rotation).setDuration(FOLD_TURN).start() else b.chevron.rotation = rotation
            // The pinned notes belong to folders of their own; a new one goes into a folder.
            val realFolder = !group.isPinned && !group.isAll && !group.isTrash
            b.add.isVisible = realFolder && !searching
            b.root.setOnClickListener { if (!searching && !group.isAll) callbacks.toggle(folder) }
            b.root.setOnLongClickListener {
                if (realFolder) callbacks.folderMenu(folder, b.name)
                realFolder
            }
            b.add.setOnClickListener { callbacks.add(folder) }
            b.root.foreground = if (folder.name == dropTarget) ColorDrawable(labels.highlight) else null
        }
    }

    /** What a tile and a row of the list have in common. */
    private abstract inner class NoteHolder(root: View) : RecyclerView.ViewHolder(root) {
        abstract val title: TextView
        abstract val edited: TextView
        abstract val preview: TextView
        abstract val thumb: ImageView

        /** The view that shows or hides with the picture. */
        open val thumbFrame: View get() = thumb

        open fun bind(note: NotesStore.Note) {
            val summary = note.summary
            val name = marked(summary.title.ifEmpty { labels.untitled })
            title.text = if (!labels.isUnsynced(note)) name else SpannableStringBuilder()
                .append("● ", ForegroundColorSpan(labels.unsyncedColor), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                .append(name)
            edited.text = labels.edited(note.modified)
            val text = snippets[note.id] ?: summary.preview
            preview.text = marked(text)
            preview.isVisible = text.isNotEmpty()
            val path = summary.image
            thumb.tag = path
            thumb.setImageDrawable(null)
            thumbFrame.isVisible = path != null
            if (path != null) thumbnail(path) { bitmap ->
                // The view may show another note by the time the picture is read.
                if (thumb.tag == path) {
                    thumb.setImageBitmap(bitmap)
                    thumbFrame.isVisible = bitmap != null
                }
            }
            itemView.setOnClickListener { callbacks.open(note) }
            itemView.alpha = 1f
            itemView.setOnLongClickListener { view ->
                view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                callbacks.startDrag(note, itemView)
                true
            }
        }
    }

    private inner class TileHolder(b: ItemNoteTileBinding) : NoteHolder(b.root) {
        override val title = b.title
        override val edited = b.edited
        override val preview = b.preview
        override val thumb = b.thumb

        init {
            // As many lines of text as the tile has room for, ending in an ellipsis.
            b.preview.addOnLayoutChangeListener { view, _, top, _, bottom, _, oldTop, _, oldBottom ->
                if (bottom - top == oldBottom - oldTop) return@addOnLayoutChangeListener
                val lines = ((bottom - top) / b.preview.lineHeight).coerceAtLeast(0)
                view.post {
                    b.preview.maxLines = lines.coerceAtLeast(1)
                    b.preview.isVisible = lines > 0 && b.preview.text.isNotEmpty()
                }
            }
        }
    }

    private inner class ListRowHolder(private val b: ItemNoteRowBinding) : NoteHolder(b.root) {
        override val title = b.title
        override val edited = b.edited
        override val preview = b.preview
        override val thumb = b.thumb
        override val thumbFrame: View get() = b.thumbFrame

        override fun bind(note: NotesStore.Note) {
            super.bind(note)
            // One line of a list shows the text as it runs on, not line by line.
            preview.text = marked((snippets[note.id] ?: note.summary.preview).replace('\n', ' '))
            b.row.setOnClickListener { callbacks.open(note) }
            b.row.setOnLongClickListener { itemView.performLongClick() }
        }
    }

    companion object {
        const val COLUMNS = 2
        private const val FOLD = "fold"
        private const val DROP = "drop"
        private const val FOLD_TURN = 200L
        private const val HEADER = 0
        private const val TILE = 1
        private const val LIST_ROW = 2
    }
}

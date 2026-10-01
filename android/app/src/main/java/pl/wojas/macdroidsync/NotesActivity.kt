package pl.wojas.macdroidsync

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.view.WindowManager
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.net.Uri
import android.widget.Toast
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import java.io.File
import java.util.concurrent.Executors
import android.os.Bundle
import android.content.res.Configuration
import android.view.View
import android.view.ViewTreeObserver
import android.view.animation.PathInterpolator
import android.widget.EditText
import android.widget.FrameLayout
import androidx.activity.OnBackPressedCallback
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.children
import androidx.core.view.isInvisible
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import androidx.core.widget.doAfterTextChanged
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import androidx.core.graphics.ColorUtils
import androidx.core.view.doOnNextLayout
import com.google.android.material.color.MaterialColors
import pl.wojas.macdroidsync.databinding.ActivityNotesBinding
import kotlin.math.roundToInt

/**
 * One note of the Markdown notes, opened from [NotesListActivity]. It is
 * read from the [NotesStore] and written back whenever the screen goes out of
 * sight; a new note left without a word in it is dropped.
 *
 * The screen shows the formatted note, read or edited with the caret shown,
 * or in its place the Markdown source as plain text, or one of its tables.
 * A picture of the note opens over all of it on the whole screen.
 */
class NotesActivity : ScreenActivity() {

    private lateinit var binding: ActivityNotesBinding
    private lateinit var editor: MarkdownEditor
    private lateinit var store: NotesStore
    private lateinit var noteId: String

    /** Set once the note is deleted, so that leaving the screen does not write it back. */
    private var deleted = false

    /** A note in the trash, shown to be read and restored, never written. */
    private var inTrash = false

    /**
     * Whether the screen holds changes the store does not have yet. Read off the
     * main thread by the sync, which leaves a note being edited alone.
     */
    @Volatile
    private var unsaved = false

    /** Set while the screen puts text in itself, which is no edit of the user's. */
    private var loading = false

    /** Saves a moment after typing stops, so that an edit reaches the Mac soon, not only on leaving. */
    private val autosave = Runnable { if (!isFinishing && openTable == null && !drawingOpen) saveNote() }

    private val storeEditor = object : NotesStore.Editor {
        override val dirty get() = unsaved
        override fun reload(markdown: String) = runOnUiThread { reloadFromSync(markdown) }
    }
    private var inSource = false
    private lateinit var images: NoteImages
    private lateinit var viewer: ImageViewer

    /** Picture files are read and written one at a time, off the main thread. */
    private val imageWork = Executors.newSingleThreadExecutor()

    private lateinit var drawing: DrawingEditor
    private var drawingOpen = false

    /** The drawing of the note being drawn on again, or null for a new one. */
    private var redrawing: NoteImageSpan? = null

    /** Back while drawing keeps the drawing, as the check mark does. */
    private val closeDrawingOnBack = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = closeDrawing(keep = true)
    }

    /** The picture of the note open on the whole screen. */
    private var viewedImage: NoteImageSpan? = null

    private lateinit var files: NoteFiles

    private val pickFile = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) importFile(uri)
    }

    private val askMicrophone = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startRecording() else Toast.makeText(this, R.string.record_needs_mic, Toast.LENGTH_SHORT).show()
    }

    /** The recording being made, and what makes it, while the toolbar shows how long it is. */
    private var recorder: MediaRecorder? = null
    private var recording: MdFile? = null
    private var recordStarted = 0L

    private val recordTick = object : Runnable {
        override fun run() {
            binding.recordTime.text = SpannableString("● " + clock(SystemClock.elapsedRealtime() - recordStarted)).apply {
                setSpan(ForegroundColorSpan(RECORDING_RED), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            binding.recordTime.postDelayed(this, 250)
        }
    }

    /** Back while recording stops it and keeps what was recorded, as the stop button does. */
    private val stopRecordingOnBack = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = stopRecording(keep = true)
    }

    /** The recording of the note playing, or paused part way through. */
    private var player: MediaPlayer? = null
    private var playing: NoteFileSpan? = null

    private val playTick = object : Runnable {
        override fun run() {
            val span = playing ?: return
            player?.let { span.position = it.currentPosition.toLong() }
            editor.redraw(span)
            if (span.playing) binding.editor.postDelayed(this, 200)
        }
    }

    private val pickImage = registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) importImage(uri)
    }

    private val takePhoto = registerForActivityResult(ActivityResultContracts.TakePicture()) { taken ->
        if (taken) importImage(cameraUri())
    }

    /** Back while a picture is on the whole screen shrinks it back into the note. */
    private val closeViewerOnBack = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = viewer.close()
    }

    /** While editing: the toolbar shows what can be inserted instead of the formatting. */
    private var inserting = false
    private lateinit var tableEditor: TableEditor

    /** The table open on the whole screen, if any. */
    private var openTable: TableSpan? = null

    /** Back while editing hides the caret and the keyboard, leaving the note to be read and scrolled. */
    private val stopEditingOnBack = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = stopEditing()
    }

    /** Back in the source goes back to the formatted note, as the close button does. */
    private val closeSourceOnBack = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = closeSource()
    }

    /** Back in a table keeps what was typed, as the check mark does. */
    private val closeTableOnBack = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = closeTable(delete = false)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        NotesTheme.apply(this)
        super.onCreate(savedInstanceState)
        binding = ActivityNotesBinding.inflate(layoutInflater)
        setContentView(binding.root)
        padFromInsets(binding.body)
        keepClearOfStatusBar(binding.page)
        keepTitleOnTop()
        keepCaretInView(binding.editorScroll, binding.editor)
        keepCaretInView(binding.sourceScroll, binding.source)
        onBackPressedDispatcher.addCallback(this, stopEditingOnBack)
        onBackPressedDispatcher.addCallback(this, closeSourceOnBack)
        onBackPressedDispatcher.addCallback(this, closeTableOnBack)
        onBackPressedDispatcher.addCallback(this, closeDrawingOnBack)
        drawing = DrawingEditor(binding.drawingScreen)
        drawing.onDone = { closeDrawing(keep = true) }
        drawing.onDiscard = { closeDrawing(keep = false) }
        // Behind the note's own buttons on the toolbar, shown only while drawing.
        drawing.tools.forEach { binding.tools.addView(it) }
        tableEditor = TableEditor(binding.tableGrid)
        tableEditor.onSelectionChanged = ::showTools
        binding.editor.setOnFocusChangeListener { _, focused ->
            stopEditingOnBack.isEnabled = focused
            if (!focused) inserting = false
            // The marks of a search are there to find the words; typing starts without them.
            if (focused) editor.clearSearchMarks()
            showTools()
        }
        stopEditingWithKeyboard()

        images = NoteImages(this)
        files = NoteFiles(this)
        viewer = ImageViewer(binding.imageViewer, window)
        // Registered last, so that it goes first while a picture is open.
        onBackPressedDispatcher.addCallback(this, closeViewerOnBack)
        onBackPressedDispatcher.addCallback(this, stopRecordingOnBack)
        viewer.onOpenChanged = { open ->
            closeViewerOnBack.isEnabled = open
            if (!open) viewedImage = null
        }
        viewer.onRotate = ::rotateImage
        viewer.onEdit = ::redrawImage
        viewer.onDelete = ::deleteImage
        editor = MarkdownEditor(binding.editor, ::editTable, images::load, files::info)
        editor.onImageTap = ::showImage
        editor.onFileTap = ::fileTapped
        editor.onStateChanged = ::showState
        binding.setUpToolbar(editor)
        store = NotesStore.shared(this)
        val id = intent.getStringExtra(EXTRA_NOTE_ID)
        val note = id?.let(store::note)
        if (id == null || note == null) {
            finish()
            return
        }
        noteId = id
        inTrash = note.deleted != null
        loading = true
        editor.setMarkdown(savedInstanceState?.getString(STATE_MARKDOWN) ?: store.read(id))
        loading = false
        unsaved = savedInstanceState?.getString(STATE_MARKDOWN)?.let { it != store.read(id) } == true
        store.attach(id, storeEditor)
        binding.editor.doAfterTextChanged { edited() }
        binding.source.doAfterTextChanged { edited() }
        if (inTrash) {
            binding.editor.showSoftInputOnFocus = false
            binding.editor.isFocusable = false
            Toast.makeText(this, R.string.note_in_trash, Toast.LENGTH_SHORT).show()
        }
        if (savedInstanceState?.getBoolean(STATE_IN_SOURCE) == true) openSource()
        showPinned()
        showTools()
        if (savedInstanceState == null) showSearch(intent.getStringExtra(EXTRA_SEARCH).orEmpty())
        // A new note starts with the caret in its title and the keyboard up.
        if (savedInstanceState == null && intent.getBooleanExtra(EXTRA_NEW, false)) {
            binding.editor.requestFocus()
            binding.editor.setSelection(minOf(1, binding.editor.length()))
            binding.editor.post {
                WindowCompat.getInsetsController(window, binding.editor).show(WindowInsetsCompat.Type.ime())
            }
        }
    }

    /**
     * Opened from a search: marks the words found and scrolls the first one
     * into view, a third of the way down, clear of the title kept on top.
     */
    private fun showSearch(query: String) {
        val words = NoteSearch.words(query)
        val color = ColorUtils.setAlphaComponent(MaterialColors.getColor(this, androidx.appcompat.R.attr.colorPrimary, 0), 0x55)
        val first = editor.markSearch(words, color) ?: return
        binding.editor.doOnNextLayout {
            binding.editor.post {
                val layout = binding.editor.layout ?: return@post
                val line = layout.getLineForOffset(first)
                val y = binding.editor.top + binding.editor.totalPaddingTop + layout.getLineTop(line)
                binding.editorScroll.scrollTo(0, (y - binding.editorScroll.height / 3).coerceAtLeast(0))
                editor.revealSideways(first)
            }
        }
    }

    override fun onPause() {
        super.onPause()
        stopRecording(keep = true)
        stopPlaying()
        saveNote()
    }

    /** The note as it stands, whichever of its screens is open. */
    private fun currentMarkdown(): String {
        openTable?.let { editor.updateTable(it, tableEditor.result()) }
        return if (inSource) binding.source.text.toString() else editor.toMarkdown()
    }

    /** Writes the note back, or drops it when leaving a note that has nothing in it. */
    private fun saveNote() {
        binding.root.removeCallbacks(autosave)
        if (deleted || inTrash || !::noteId.isInitialized) return
        val markdown = currentMarkdown()
        if (isFinishing && isBlank(markdown)) {
            store.discard(noteId)
            deleted = true
        } else if (!isBlank(markdown) || isFinishing) {
            // A note emptied while it is open is not written as it goes: the Mac
            // would take an empty note for one to delete.
            store.save(noteId, markdown)
            unsaved = false
        }
    }

    private fun edited() {
        if (loading || inTrash) return
        unsaved = true
        binding.root.removeCallbacks(autosave)
        binding.root.postDelayed(autosave, AUTOSAVE_DELAY_MS)
    }

    /**
     * The Mac changed the note while it is open here. Shown at once unless
     * something has been typed since the last save, or a table, a drawing or
     * the source is open; then the next save is what the Mac gets back.
     */
    private fun reloadFromSync(markdown: String) {
        if (unsaved || inSource || openTable != null || drawingOpen || isFinishing) return
        val caret = binding.editor.selectionStart
        val scroll = binding.editorScroll.scrollY
        loading = true
        editor.setMarkdown(markdown)
        loading = false
        if (binding.editor.hasFocus() && caret >= 0) binding.editor.setSelection(minOf(caret, binding.editor.length()))
        binding.editorScroll.post { binding.editorScroll.scrollTo(0, scroll) }
    }

    private fun isBlank(markdown: String) = Markdown.parse(markdown).all {
        it.table == null && it.image == null && it.file == null && it.text.isBlank()
    }

    private fun showPinned() {
        val pinned = store.note(noteId)?.pinned == true
        binding.toolPin.setImageResource(if (pinned) R.drawable.ic_tool_pin_filled else R.drawable.ic_tool_pin)
        binding.toolPin.isSelected = pinned
        val label = getString(if (pinned) R.string.note_unpin else R.string.note_pin)
        binding.toolPin.contentDescription = label
        binding.toolPin.tooltipText = label
    }

    private fun togglePinned() {
        store.setPinned(noteId, store.note(noteId)?.pinned != true)
        showPinned()
    }

    /** Offers the folders, the note's own ticked, and a new folder at the end. */
    private fun moveNote() {
        val folders = store.folders.map { it.name }
        val current = folders.indexOf(store.note(noteId)?.folder)
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.note_move)
            .setSingleChoiceItems(folders.toTypedArray(), current) { dialog, which ->
                dialog.dismiss()
                if (which != current) moveNote(folders[which])
            }
            .setNeutralButton(R.string.notes_new_folder) { _, _ -> askNewFolder() }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun moveNote(folder: String) {
        store.move(noteId, folder)
        Toast.makeText(this, getString(R.string.note_moved, folder), Toast.LENGTH_SHORT).show()
    }

    private fun askNewFolder() {
        val padding = (20 * resources.displayMetrics.density).roundToInt()
        val field = EditText(this).apply {
            setHint(R.string.notes_folder_name)
            isSingleLine = true
        }
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.notes_new_folder)
            .setView(FrameLayout(this).apply {
                setPadding(padding, padding / 2, padding, 0)
                addView(field)
            })
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val name = field.text.toString().trim()
                when {
                    name.isEmpty() -> Unit
                    store.addFolder(name) || store.folder(name) != null -> moveNote(name)
                }
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
        field.requestFocus()
    }

    private fun copyNote() {
        store.save(noteId, currentMarkdown())
        if (store.copy(noteId, getString(R.string.note_copy_suffix)) != null) {
            Toast.makeText(this, R.string.note_copied, Toast.LENGTH_SHORT).show()
        }
    }

    /** Back out of the trash, and the screen becomes an ordinary note screen. */
    private fun restoreNote() {
        store.restore(noteId)
        inTrash = false
        binding.editor.isFocusable = true
        binding.editor.isFocusableInTouchMode = true
        showTools()
    }

    private fun deleteForever() {
        MaterialAlertDialogBuilder(this)
            .setMessage(R.string.note_delete_forever_confirm)
            .setPositiveButton(R.string.note_delete_forever) { _, _ ->
                deleted = true
                store.deleteForever(noteId)
                finish()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun deleteNote() {
        val title = NoteSummary.of(currentMarkdown()).title.ifEmpty { getString(R.string.notes_untitled) }
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.note_delete)
            .setMessage(getString(R.string.note_delete_message, title))
            .setPositiveButton(R.string.action_delete) { _, _ ->
                deleted = true
                store.delete(noteId)
                finish()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        // A table being edited goes into the note that is carried over, while its screen stays open.
        openTable?.let { editor.updateTable(it, tableEditor.result()) }
        outState.putString(STATE_MARKDOWN, if (inSource) binding.source.text.toString() else editor.toMarkdown())
        outState.putBoolean(STATE_IN_SOURCE, inSource)
    }

    /**
     * When the keyboard opens, the scroll view shrinks but only keeps the field
     * as a whole on screen, so a caret near the bottom would end up behind the
     * keyboard. Once the smaller size is laid out, the caret is brought back,
     * and after every edit too, since the field alone would leave a new line
     * flush against the toolbar.
     */
    private fun keepCaretInView(scroll: View, field: EditText) {
        scroll.addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
            if (bottom - top < oldBottom - oldTop && field.hasFocus()) field.post { showCaret(field) }
        }
        field.doAfterTextChanged { if (field.hasFocus()) field.post { showCaret(field) } }
    }

    /**
     * Reading needs only folding and the source, editing gets the formatting
     * buttons instead, or what can be inserted once the insert button asks
     * for it, and the source only the button that closes it.
     */
    private fun showTools() = with(binding) {
        val tableTools = setOf(
            toolTableDone, toolRowAdd, toolColumnAdd, toolMoveUp, toolMoveDown, toolMoveLeft, toolMoveRight,
            toolRowRemove, toolColumnRemove, toolTableDelete,
        )
        val readingTools = setOf(toolFoldAll, toolShowMarkdown, toolPin, toolMoveNote, toolCopyNote, toolDeleteNote)
        val trashTools = setOf(toolRestore, toolDeleteForever)
        val insertTools = setOf(toolInsertClose, toolTable, toolImageGallery, toolImageCamera, toolDrawing, toolFile, toolRecord)
        val recordTools = setOf(toolRecordCancel, recordTime, toolRecordStop)
        val drawTools = drawing.tools.toSet()
        val shown = when {
            inTrash -> trashTools
            recording != null -> recordTools
            inSource -> setOf(toolCloseMarkdown)
            drawingOpen -> drawTools
            openTable != null -> tableToolsShown()
            editor.hasFocus() && inserting -> insertTools
            editor.hasFocus() -> tools.children.toSet() - readingTools - trashTools - toolCloseMarkdown - tableTools - insertTools - drawTools - recordTools
            else -> readingTools
        }
        taskCount.isVisible = shown == readingTools && taskCount.text.isNotEmpty()
        val wasShown = tools.children.filter { it.isVisible }.toSet()
        for (tool in tools.children) tool.isVisible = tool in shown
        if (shown != wasShown) toolsScroll.scrollTo(0, 0)
    }

    /**
     * Adding is always there. Moving and deleting need a whole row or column
     * selected, and then the table itself cannot be deleted from here, so the
     * two bins are never side by side.
     */
    private fun ActivityNotesBinding.tableToolsShown(): Set<View> {
        val table = tableEditor
        val selection = table.selection
        fun View.enable(on: Boolean) = apply {
            isEnabled = on
            alpha = if (on) 1f else 0.38f
        }
        return when (selection?.axis) {
            TableEditor.Axis.ROW -> setOf(
                toolTableDone, toolRowAdd, toolColumnAdd,
                toolMoveUp.enable(selection.index > 0),
                toolMoveDown.enable(selection.index < table.rowCount - 1),
                toolRowRemove.enable(table.rowCount > 1),
            )
            TableEditor.Axis.COLUMN -> setOf(
                toolTableDone, toolRowAdd, toolColumnAdd,
                toolMoveLeft.enable(selection.index > 0),
                toolMoveRight.enable(selection.index < table.columnCount - 1),
                toolColumnRemove.enable(table.columnCount > 1),
            )
            null -> setOf(toolTableDone, toolRowAdd, toolColumnAdd, toolTableDelete)
        }
    }


    /**
     * The note's first line is its title. Once it has scrolled out of sight a
     * one line copy of it stays at the top, and tapping that goes back up.
     */
    private fun keepTitleOnTop() = with(binding) {
        fun update() {
            val layout = editor.layout
            val passed = layout != null && editorScroll.isVisible &&
                editorScroll.scrollY > editor.top + editor.totalPaddingTop + layout.getLineBottom(0)
            if (passed) stickyTitleText.text = editor.text?.let { t -> t.substring(0, t.indexOf('\n').let { if (it < 0) t.length else it }) }
                ?.filter { it != MARK }
            stickyTitle.isVisible = passed
        }
        editorScroll.setOnScrollChangeListener { _: View, _: Int, _: Int, _: Int, _: Int -> update() }
        editor.doAfterTextChanged { update() }
        stickyTitle.setOnClickListener { editorScroll.smoothScrollTo(0, 0) }
    }

    /** The one file the camera app writes to; each photo is copied into the note's pictures right after. */
    private fun cameraUri(): Uri {
        val file = File(cacheDir, "camera/photo.jpg")
        file.parentFile?.mkdirs()
        return FileProvider.getUriForFile(this, "$packageName.mms", file)
    }

    /** Copies the picture in off the main thread, then puts it below the caret's line. */
    private fun importImage(uri: Uri) {
        imageWork.execute {
            val image = images.import(uri)
            runOnUiThread {
                if (image == null) {
                    Toast.makeText(this, R.string.image_import_failed, Toast.LENGTH_SHORT).show()
                    return@runOnUiThread
                }
                inserting = false
                editor.insertImage(image)
                showTools()
            }
        }
    }

    /**
     * Turns the picture open on the whole screen and keeps it turned: the file
     * is written over in the background, and the note shows it once written.
     */
    private fun rotateImage(bitmap: Bitmap, degrees: Int): Bitmap? {
        val span = viewedImage ?: return null
        val turned = images.turned(bitmap, degrees)
        imageWork.execute {
            images.save(span.image, turned)
            runOnUiThread { editor.reloadImage(span) }
        }
        return turned
    }

    override fun onDestroy() {
        super.onDestroy()
        if (::noteId.isInitialized) store.detach(noteId, storeEditor)
        imageWork.shutdown()
    }

    // region Files and recordings

    /** Copies the file in off the main thread, then puts its tile below the caret's line. */
    private fun importFile(uri: Uri) {
        imageWork.execute {
            val file = files.import(uri)
            runOnUiThread {
                if (file == null) {
                    Toast.makeText(this, R.string.file_import_failed, Toast.LENGTH_SHORT).show()
                    return@runOnUiThread
                }
                inserting = false
                editor.insertFile(file)
                showTools()
            }
        }
    }

    /** A recording plays where it is; any other file opens in an app for it. The dots offer the rest. */
    private fun fileTapped(span: NoteFileSpan, part: NoteFileSpan.Part) {
        when {
            part == NoteFileSpan.Part.MENU -> fileMenu(span)
            span.file.isAudio -> togglePlaying(span)
            else -> openFile(span.file)
        }
    }

    private fun fileMenu(span: NoteFileSpan) {
        val actions = listOf(R.string.file_open, R.string.file_share, R.string.file_delete)
        MaterialAlertDialogBuilder(this)
            .setTitle(span.file.name)
            .setItems(actions.map { getString(it) }.toTypedArray()) { _, which ->
                when (actions[which]) {
                    R.string.file_open -> openFile(span.file)
                    R.string.file_share -> shareFile(span.file)
                    R.string.file_delete -> deleteFile(span)
                }
            }
            .show()
    }

    private fun openFile(file: MdFile) {
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(files.uri(file), files.mimeType(file))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        runCatching { startActivity(intent) }.onFailure {
            Toast.makeText(this, R.string.file_no_app, Toast.LENGTH_SHORT).show()
        }
    }

    private fun shareFile(file: MdFile) {
        val uri = files.uri(file)
        val intent = Intent(Intent.ACTION_SEND)
            .setType(files.mimeType(file))
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        intent.clipData = android.content.ClipData.newRawUri(file.name, uri)
        startActivity(Intent.createChooser(intent, file.name))
    }

    private fun deleteFile(span: NoteFileSpan) {
        if (playing == span) stopPlaying()
        editor.removeObject(span)
        imageWork.execute { files.delete(span.file) }
    }

    private fun togglePlaying(span: NoteFileSpan) {
        val current = player
        if (current != null && playing == span) {
            if (span.playing) current.pause() else current.start()
            span.playing = !span.playing
            playTick.run()
            return
        }
        stopPlaying()
        val started = runCatching {
            MediaPlayer().apply {
                setDataSource(files.file(span.file).path)
                prepare()
                if (span.position in 1 until duration) seekTo(span.position.toInt())
                setOnCompletionListener {
                    span.position = 0
                    stopPlaying()
                }
                start()
            }
        }.getOrNull()
        if (started == null) {
            Toast.makeText(this, R.string.file_no_app, Toast.LENGTH_SHORT).show()
            return
        }
        player = started
        playing = span
        span.playing = true
        playTick.run()
    }

    /** Stops the recording playing, if any; it starts from where it was the next time. */
    private fun stopPlaying() {
        val span = playing ?: return
        player?.let { span.position = if (span.position == 0L) 0L else it.currentPosition.toLong() }
        player?.release()
        player = null
        playing = null
        span.playing = false
        binding.editor.removeCallbacks(playTick)
        editor.redraw(span)
    }

    private fun record() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            startRecording()
        } else {
            askMicrophone.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    private fun startRecording() {
        if (recording != null) return
        stopPlaying()
        val file = files.newRecording(getString(R.string.recording_name))
        val started = runCatching {
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(this) else @Suppress("DEPRECATION") MediaRecorder()).apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioEncodingBitRate(RECORD_BIT_RATE)
                setAudioSamplingRate(RECORD_SAMPLE_RATE)
                setOutputFile(files.file(file).path)
                prepare()
                start()
            }
        }.getOrNull()
        if (started == null) {
            files.delete(file)
            Toast.makeText(this, R.string.record_failed, Toast.LENGTH_SHORT).show()
            return
        }
        recorder = started
        recording = file
        recordStarted = SystemClock.elapsedRealtime()
        stopRecordingOnBack.isEnabled = true
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        recordTick.run()
        showTools()
    }

    /** Ends the recording, putting it below the caret's line when [keep] and it recorded anything. */
    private fun stopRecording(keep: Boolean) {
        val active = recorder ?: return
        val file = recording ?: return
        val recorded = runCatching { active.stop() }.isSuccess
        active.release()
        recorder = null
        recording = null
        stopRecordingOnBack.isEnabled = false
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        binding.recordTime.removeCallbacks(recordTick)
        if (keep && recorded) {
            inserting = false
            editor.insertFile(file)
        } else {
            files.delete(file)
        }
        showTools()
    }

    private fun clock(ms: Long): String {
        val seconds = ms / 1000
        return "%d:%02d".format(seconds / 60, seconds % 60)
    }

    // endregion

    /**
     * A drawing sheet over the whole note: empty, the drawing then going below
     * the caret's line, or with the strokes of [redraw] to change that one.
     */
    private fun openDrawing(redraw: NoteImageSpan? = null, strokes: String? = null) {
        inserting = false
        stopEditing()
        redrawing = redraw
        drawing.open(strokes)
        drawingOpen = true
        binding.stickyTitle.isVisible = false
        binding.drawingScreen.alpha = 0f
        binding.drawingScreen.isVisible = true
        binding.drawingScreen.animate().alpha(1f).setDuration(DRAWING_FADE).withEndAction {
            binding.editorScroll.isInvisible = true
        }.start()
        closeDrawingOnBack.isEnabled = true
        showTools()
    }

    /** Puts the drawing into the note when [keep] is set and something was drawn, then goes back to the note. */
    private fun closeDrawing(keep: Boolean) {
        if (!drawingOpen) return
        val sheet = if (keep) drawing.canvas.export() else null
        drawingOpen = false
        closeDrawingOnBack.isEnabled = false
        binding.editorScroll.isInvisible = false
        binding.drawingScreen.animate().alpha(0f).setDuration(DRAWING_FADE).withEndAction {
            binding.drawingScreen.isVisible = false
            binding.drawingScreen.alpha = 1f
        }.start()
        showTools()
        val redraw = redrawing
        redrawing = null
        if (sheet == null) return
        val strokes = drawing.canvas.save()
        val alt = getString(R.string.drawing_alt)
        imageWork.execute {
            val image = images.saveDrawing(sheet, strokes, alt, redraw?.image)
            runOnUiThread {
                when {
                    image == null -> Toast.makeText(this, R.string.image_import_failed, Toast.LENGTH_SHORT).show()
                    redraw != null -> editor.reloadImage(redraw)
                    else -> editor.insertImage(image)
                }
            }
        }
    }

    /** Leaves the picture on the whole screen for the drawing sheet, with its strokes. */
    private fun redrawImage() {
        val span = viewedImage ?: return
        val strokes = images.drawing(span.image) ?: return
        viewer.close { openDrawing(span, strokes) }
    }

    /** Takes the picture open on the whole screen out of the note; it fades away. */
    private fun deleteImage() {
        val span = viewedImage ?: return
        editor.removeObject(span)
        viewer.close()
        imageWork.execute { images.delete(span.image) }
    }

    /** Opens a tapped picture on the whole screen, growing out of where it is in the note. */
    private fun showImage(span: NoteImageSpan, inEditor: RectF) {
        val bitmap = images.load(span.image, FULL_SCREEN_WIDTH) ?: span.bitmap() ?: return
        viewedImage = span
        viewer.open(bitmap, toViewer(inEditor), drawing = images.drawing(span.image) != null) { editor.bounds(span)?.let(::toViewer) }
    }

    private fun toViewer(inEditor: RectF): RectF {
        val editorAt = IntArray(2).also(binding.editor::getLocationInWindow)
        val viewerAt = IntArray(2).also(binding.imageViewer::getLocationInWindow)
        return RectF(inEditor).apply { offset((editorAt[0] - viewerAt[0]).toFloat(), (editorAt[1] - viewerAt[1]).toFloat()) }
    }

    private fun showInsertTools(show: Boolean) {
        inserting = show
        showTools()
    }

    /** Puts the note's Markdown in place of the formatted note, to be edited as plain text. */
    private fun openSource() {
        if (inSource) return
        stopEditing()
        binding.source.setText(editor.toMarkdown())
        binding.noteFrame.isVisible = false
        binding.sourceScroll.isVisible = true
        binding.sourceScroll.scrollTo(0, 0)
        inSource = true
        closeSourceOnBack.isEnabled = true
        showTools()
    }

    /** Reads the edited source back into the formatted note. */
    private fun closeSource() {
        if (!inSource) return
        binding.source.clearFocus()
        WindowCompat.getInsetsController(window, binding.source).hide(WindowInsetsCompat.Type.ime())
        editor.setMarkdown(binding.source.text.toString())
        binding.sourceScroll.isVisible = false
        binding.noteFrame.isVisible = true
        binding.editorScroll.scrollTo(0, 0)
        inSource = false
        closeSourceOnBack.isEnabled = false
        showTools()
    }

    private fun stopEditing() {
        binding.editor.clearFocus()
        WindowCompat.getInsetsController(window, binding.editor).hide(WindowInsetsCompat.Type.ime())
    }

    /**
     * The first back while the keyboard is up goes to the keyboard, which only
     * closes. Watching it close is what lets that one back hide the caret too.
     */
    private fun stopEditingWithKeyboard() {
        var keyboardShown = false
        ViewCompat.setOnApplyWindowInsetsListener(binding.editor) { _, insets ->
            val shown = insets.isVisible(WindowInsetsCompat.Type.ime())
            if (keyboardShown && !shown && binding.editor.hasFocus()) binding.editor.post { stopEditing() }
            keyboardShown = shown
            insets
        }
    }

    /** Scrolls the caret's line into view with room below it for the caret handle. */
    private fun showCaret(editor: EditText) {
        val layout = editor.layout ?: return
        val line = layout.getLineForOffset(editor.selectionEnd.coerceAtLeast(0))
        val room = (48 * resources.displayMetrics.density).roundToInt()
        val top = editor.totalPaddingTop + layout.getLineTop(line)
        editor.requestRectangleOnScreen(Rect(0, top, editor.width, editor.totalPaddingTop + layout.getLineBottom(line) + room))
    }

    /** An extension of the binding so its buttons read plainly; its own editor is the text field, hence notes. */
    private fun ActivityNotesBinding.setUpToolbar(notes: MarkdownEditor) {
        toolUnderline.paintFlags = toolUnderline.paintFlags or Paint.UNDERLINE_TEXT_FLAG
        toolFoldAll.setOnClickListener { notes.toggleAllHeadings() }
        toolShowMarkdown.setOnClickListener { openSource() }
        toolPin.setOnClickListener { togglePinned() }
        toolMoveNote.setOnClickListener { moveNote() }
        toolCopyNote.setOnClickListener { copyNote() }
        toolDeleteNote.setOnClickListener { deleteNote() }
        toolRestore.setOnClickListener { restoreNote() }
        toolDeleteForever.setOnClickListener { deleteForever() }
        toolCloseMarkdown.setOnClickListener { closeSource() }
        toolTableDone.setOnClickListener { closeTable(delete = false) }
        toolRowAdd.setOnClickListener { tableEditor.addRow() }
        toolColumnAdd.setOnClickListener { tableEditor.addColumn() }
        toolMoveUp.setOnClickListener { tableEditor.moveSelection(forward = false) }
        toolMoveDown.setOnClickListener { tableEditor.moveSelection(forward = true) }
        toolMoveLeft.setOnClickListener { tableEditor.moveSelection(forward = false) }
        toolMoveRight.setOnClickListener { tableEditor.moveSelection(forward = true) }
        toolRowRemove.setOnClickListener { tableEditor.deleteSelection() }
        toolColumnRemove.setOnClickListener { tableEditor.deleteSelection() }
        toolTableDelete.setOnClickListener { closeTable(delete = true) }
        toolBold.setOnClickListener { notes.toggleInline(Inline.BOLD) }
        toolItalic.setOnClickListener { notes.toggleInline(Inline.ITALIC) }
        toolUnderline.setOnClickListener { notes.toggleInline(Inline.UNDERLINE) }
        toolCode.setOnClickListener { notes.toggleInline(Inline.CODE) }
        toolCodeBlock.setOnClickListener { notes.toggleBlock(BlockType.CODE) }
        toolHeading.setOnClickListener { notes.cycleHeading() }
        toolBullets.setOnClickListener { notes.toggleBlock(BlockType.BULLET) }
        toolNumbered.setOnClickListener { notes.toggleBlock(BlockType.NUMBERED) }
        toolCheckbox.setOnClickListener { notes.toggleBlock(BlockType.CHECKBOX) }
        toolQuote.setOnClickListener { notes.toggleBlock(BlockType.QUOTE) }
        toolInsert.setOnClickListener { showInsertTools(true) }
        toolInsertClose.setOnClickListener { showInsertTools(false) }
        toolImageGallery.setOnClickListener {
            pickImage.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
        }
        toolImageCamera.setOnClickListener { takePhoto.launch(cameraUri()) }
        toolDrawing.setOnClickListener { openDrawing() }
        toolFile.setOnClickListener { pickFile.launch(arrayOf("*/*")) }
        toolRecord.setOnClickListener { record() }
        toolRecordStop.setOnClickListener { stopRecording(keep = true) }
        toolRecordCancel.setOnClickListener { stopRecording(keep = false) }
        toolTable.setOnClickListener {
            // The table opens on its own screen; editing resumes with the formatting.
            inserting = false
            notes.insertTable()
        }
    }

    /** Lights up the buttons whose style or block applies where the caret is. */
    private fun showState(state: MarkdownEditor.State) = with(binding) {
        // The button shows what it will do: unfold once everything is folded.
        val label = getString(if (state.allFolded) R.string.tool_unfold_all else R.string.tool_fold_all)
        toolFoldAll.setImageResource(if (state.allFolded) R.drawable.ic_tool_unfold else R.drawable.ic_tool_fold)
        toolFoldAll.contentDescription = label
        toolFoldAll.tooltipText = label
        taskCount.text = if (state.tasks == 0) "" else resources.getQuantityString(R.plurals.note_tasks, state.tasks, state.tasks) + "\n" +
            if (state.open == 0) getString(R.string.note_tasks_done) else getString(R.string.note_tasks_open, state.open)
        taskCount.isVisible = toolPin.isVisible && state.tasks > 0
        toolBold.isSelected = Inline.BOLD in state.inline
        toolItalic.isSelected = Inline.ITALIC in state.inline
        toolUnderline.isSelected = Inline.UNDERLINE in state.inline
        toolCode.isSelected = Inline.CODE in state.inline
        val level = state.block.level.takeIf { state.block.type == BlockType.HEADING }
        toolHeading.isSelected = level != null
        toolHeading.text = if (level != null) "H$level" else "H"
        toolBullets.isSelected = state.block.type == BlockType.BULLET
        toolNumbered.isSelected = state.block.type == BlockType.NUMBERED
        toolCheckbox.isSelected = state.block.type == BlockType.CHECKBOX
        toolQuote.isSelected = state.block.type == BlockType.QUOTE
        toolCodeBlock.isSelected = state.block.type == BlockType.CODE
    }

    /** Puts one table on the whole screen in place of the note. */
    private fun editTable(span: TableSpan) {
        stopEditing()
        openTable = span
        binding.stickyTitle.isVisible = false
        binding.tableScroll.isVisible = true
        binding.tableScroll.scrollTo(0, 0)
        tableEditor.open(span.table)
        closeTableOnBack.isEnabled = true
        showTools()
        val from = editor.bounds(span)?.let(::toNoteFrame)
        binding.tableScroll.post {
            growTable(from, opening = true) { binding.editorScroll.isInvisible = true }
        }
    }

    /** Writes the table back into the note, or takes it out of the note when [delete] is set. */
    private fun closeTable(delete: Boolean) {
        val span = openTable ?: return
        editor.updateTable(span, if (delete) null else tableEditor.result())
        openTable = null
        currentFocus?.clearFocus()
        WindowCompat.getInsetsController(window, binding.tableGrid).hide(WindowInsetsCompat.Type.ime())
        binding.editorScroll.isInvisible = false
        closeTableOnBack.isEnabled = false
        showTools()
        // Shrinks into the table as the note now draws it, once it has.
        afterNextDraw(binding.editor) {
            growTable(if (delete) null else editor.bounds(span)?.let(::toNoteFrame), opening = false) {
                binding.tableScroll.isVisible = false
            }
        }
    }

    /**
     * Grows the table screen out of [rect], where the table is in the note, or
     * shrinks it back into it, fading as it goes. Without a rect, as for a new
     * table not drawn yet or a deleted one, it only fades.
     */
    private fun growTable(rect: RectF?, opening: Boolean, done: () -> Unit) {
        val screen = binding.tableScroll
        screen.pivotX = 0f
        screen.pivotY = 0f
        val scale = rect?.let { it.width() / screen.width.coerceAtLeast(1) } ?: 1f
        val small = { view: View ->
            view.scaleX = scale
            view.scaleY = scale
            view.translationX = rect?.left ?: 0f
            view.translationY = rect?.top ?: 0f
            view.alpha = 0f
        }
        val easing = PathInterpolator(0.2f, 0f, 0f, 1f)
        if (opening) {
            small(screen)
            screen.animate().scaleX(1f).scaleY(1f).translationX(0f).translationY(0f).alpha(1f)
        } else {
            screen.animate().scaleX(scale).scaleY(scale).translationX(rect?.left ?: 0f).translationY(rect?.top ?: 0f).alpha(0f)
        }.setDuration(TABLE_GROW).setInterpolator(easing).withEndAction {
            screen.scaleX = 1f
            screen.scaleY = 1f
            screen.translationX = 0f
            screen.translationY = 0f
            screen.alpha = 1f
            done()
        }.start()
    }

    private fun toNoteFrame(inEditor: RectF): RectF {
        val editorAt = IntArray(2).also(binding.editor::getLocationInWindow)
        val frameAt = IntArray(2).also(binding.noteFrame::getLocationInWindow)
        return RectF(inEditor).apply { offset((editorAt[0] - frameAt[0]).toFloat(), (editorAt[1] - frameAt[1]).toFloat()) }
    }

    /** Runs [action] once [view] has drawn again, so that what it draws is up to date. */
    private fun afterNextDraw(view: View, action: () -> Unit) {
        val listener = object : ViewTreeObserver.OnDrawListener {
            override fun onDraw() {
                view.post {
                    view.viewTreeObserver.removeOnDrawListener(this)
                    action()
                }
            }
        }
        view.viewTreeObserver.addOnDrawListener(listener)
        view.invalidate()
    }

    companion object {
        private const val RECORD_BIT_RATE = 96_000
        private const val AUTOSAVE_DELAY_MS = 1500L
        private const val RECORD_SAMPLE_RATE = 44_100
        private const val RECORDING_RED = 0xFFE5383B.toInt()

        const val EXTRA_NOTE_ID = "noteId"

        /** The note was just made: it opens ready to type its title into. */
        const val EXTRA_NEW = "new"

        /** The search the note was found by, whose words are to be marked and shown. */
        const val EXTRA_SEARCH = "search"

        private const val STATE_MARKDOWN = "markdown"

        /** Pictures open on the whole screen at their full stored size, which is at most 2048 pixels. */
        private const val FULL_SCREEN_WIDTH = 4096
        private const val STATE_IN_SOURCE = "inSource"
        private const val TABLE_GROW = 300L
        private const val DRAWING_FADE = 200L
    }
}

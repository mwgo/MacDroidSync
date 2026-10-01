package pl.wojas.macdroidsync

import android.app.Activity
import android.app.TaskStackBuilder
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.core.content.IntentCompat
import java.io.File
import kotlin.concurrent.thread

/**
 * Target of the system share sheet that makes a new note of what is shared:
 * its text, and below it the pictures, and the other files as tiles. The note goes into the first folder and
 * opens on top of the notes list. The window is transparent and stays up only
 * while the files are copied in, as the permission to read them ends with it.
 */
class NoteShareActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val uris = incomingUris()
        if (text.isNullOrBlank() && uris.isEmpty()) {
            Toast.makeText(this, R.string.note_share_nothing, Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        thread {
            val images = NoteImages(this)
            val files = NoteFiles(this)
            val (imageUris, fileUris) = uris.partition { contentResolver.getType(it)?.startsWith("image/") == true }
            val pictures = imageUris.mapNotNull { images.import(it) }
            val attached = fileUris.mapNotNull { files.import(it) }
            val shared = SharedNote.of(subject, text, pictures, attached)
            val store = NotesStore.shared(this)
            val folder = store.folders.firstOrNull()?.name
                ?: getString(R.string.notes_default_folder).also { store.addFolder(it) }
            val note = store.create(folder, shared.markdown)
            runOnUiThread { open(note.id, untitled = shared.untitled) }
        }
    }

    /** The note over the notes list, in the notes' own task, as if opened from there. */
    private fun open(id: String, untitled: Boolean) {
        val note = Intent(this, NotesActivity::class.java)
            .putExtra(NotesActivity.EXTRA_NOTE_ID, id)
            // Without a title to go by, the caret waits in the title for one.
            .putExtra(NotesActivity.EXTRA_NEW, untitled)
        TaskStackBuilder.create(this).addNextIntentWithParentStack(note).startActivities()
        finish()
    }

    /** The files shared; the text comes in the extras. */
    private fun incomingUris(): List<Uri> =
        when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE ->
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)?.filterNotNull().orEmpty()
            else -> emptyList()
        }
}

/** The Markdown of a note made of shared [subject], [text], pictures and files. */
data class SharedNote(val markdown: String, val untitled: Boolean) {
    companion object {
        /** A first line short enough to be a title, when the text goes on after it. */
        private const val TITLE_LIMIT = 80

        fun of(subject: String?, text: String?, pictures: List<MdImage>, files: List<MdFile> = emptyList()): SharedNote {
            val body = text?.trim().orEmpty()
            val lines = body.lines()
            val (title, rest) = when {
                !subject.isNullOrBlank() -> subject.trim().replace('\n', ' ') to body
                lines.size > 1 && lines[0].length <= TITLE_LIMIT -> lines[0].trim() to lines.drop(1).joinToString("\n").trim()
                else -> "" to body
            }
            val parts = listOfNotNull(rest.takeIf { it.isNotEmpty() }) + pictures.map { "![${it.alt}](${it.path})" } + files.map(Markdown::fileToMarkdown)
            return SharedNote("# $title\n" + parts.joinToString("\n"), untitled = title.isEmpty())
        }
    }
}

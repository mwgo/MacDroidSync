package pl.wojas.macdroidsync

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The files attached to notes, recordings among them, kept in the app's own
 * storage under notes/files, each in a folder of its own under its own name.
 */
class NoteFiles(private val context: Context) {

    private val folder = File(context.filesDir, "notes")

    /** How big a file is, and for a recording how long, in milliseconds; 0 when not known. */
    data class Info(val size: Long, val duration: Long)

    fun file(file: MdFile) = File(folder, file.path)

    /** Copies the file at [uri] in under the name it has there. Slow enough to be kept off the main thread. */
    fun import(uri: Uri): MdFile? {
        val name = displayName(uri) ?: uri.lastPathSegment?.substringAfterLast('/') ?: "file"
        val attached = MdFile(MdFile.pathFor(name), name)
        val target = file(attached)
        return runCatching {
            context.contentResolver.openInputStream(uri)!!.use { input ->
                target.parentFile?.mkdirs()
                target.outputStream().use { input.copyTo(it) }
            }
            attached
        }.onFailure { delete(attached) }.getOrNull()
    }

    private fun displayName(uri: Uri): String? = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }
    }.getOrNull()?.takeIf { it.isNotBlank() }

    /** Where a recording starting now is written, named after when it was made. */
    fun newRecording(label: String): MdFile {
        val now = Date()
        val stamp = SimpleDateFormat("yyyy-MM-dd HH.mm.ss", Locale.ROOT).format(now)
        val name = label + " " + SimpleDateFormat("MMM d, HH:mm", Locale.ENGLISH).format(now)
        val recording = MdFile(MdFile.pathFor("$label $stamp.m4a"), name)
        file(recording).parentFile?.mkdirs()
        return recording
    }

    fun info(file: MdFile): Info {
        val f = file(file)
        val duration = if (file.isAudio && f.isFile) {
            runCatching {
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(f.path)
                    retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                } finally {
                    retriever.release()
                }
            }.getOrDefault(0L)
        } else {
            0L
        }
        return Info(if (f.isFile) f.length() else 0L, duration)
    }

    /** The file as other apps can be given it to open or share. */
    fun uri(file: MdFile): Uri = FileProvider.getUriForFile(context, "${context.packageName}.mms", file(file))

    fun mimeType(file: MdFile): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension) ?: "application/octet-stream"

    /** Removes the file with the folder it has to itself. */
    fun delete(file: MdFile) {
        val f = file(file)
        f.delete()
        f.parentFile?.delete()
    }
}

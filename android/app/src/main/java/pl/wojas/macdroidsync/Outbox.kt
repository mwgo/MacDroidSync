package pl.wojas.macdroidsync

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import java.io.File
import java.io.IOException
import java.security.MessageDigest

/**
 * Staging area and queue for files on their way to the Mac.
 *
 * A file shared from another app arrives as a `content://` URI whose read
 * permission dies with the activity that received the intent, so the bytes are
 * copied into the app cache while [ShareActivity] is still alive. That copy
 * doubles as the offline queue: whatever sits here is sent at the next
 * connection, even after the process has been killed in between.
 *
 * Layout: `cacheDir/outbox/<ordered id>/<original file name>`. The directory name
 * carries the queue order, the file name carries the metadata, so no sidecar
 * files are needed. A copy in progress is suffixed `.part` and ignored by
 * [items] until it is complete.
 */
class Outbox(context: Context) {

    private val root = File(context.cacheDir, DIRECTORY)
    private val resolver = context.contentResolver

    /** One staged file waiting to be sent. */
    data class Item(val file: File, val mime: String) {
        val name: String get() = file.name
        val size: Long get() = file.length()
    }

    /** Outcome of staging one shared URI, so the caller can explain itself. */
    sealed interface Staged {
        data class Ok(val item: Item) : Staged
        data class TooLarge(val name: String) : Staged
        data class Failed(val name: String) : Staged
    }

    /** Oldest first, so files leave in the order they were shared. */
    fun items(): List<Item> =
        (root.listFiles() ?: emptyArray())
            .filter { it.isDirectory }
            .sortedBy { it.name }
            .mapNotNull { directory ->
                directory.listFiles()
                    ?.firstOrNull { it.isFile && !it.name.endsWith(PART_SUFFIX) }
                    ?.let { Item(it, mimeOf(it.name)) }
            }

    fun isEmpty(): Boolean = items().isEmpty()

    fun totalBytes(): Long = items().sumOf { it.size }

    /**
     * Copies a shared file into the cache. Must be called while the URI
     * permission is still granted, that is from the activity that received the
     * share intent.
     */
    fun enqueue(uri: Uri): Staged {
        val name = sanitize(displayName(uri))
        val alreadyQueued = totalBytes()
        val directory = File(root, "%013d-%04d".format(System.currentTimeMillis(), (0..9999).random()))
        if (!directory.mkdirs()) {
            Log.w(TAG, "Could not create the staging directory for $name")
            return Staged.Failed(name)
        }

        val part = File(directory, name + PART_SUFFIX)
        var overflow = false
        try {
            val input = resolver.openInputStream(uri) ?: throw IOException("no stream for $uri")
            input.use { source ->
                part.outputStream().use { sink ->
                    val buffer = ByteArray(64 * 1024)
                    var copied = 0L
                    while (true) {
                        val read = source.read(buffer)
                        if (read < 0) break
                        copied += read
                        if (copied > Wire.MAX_FILE_BYTES || alreadyQueued + copied > QUEUE_LIMIT_BYTES) {
                            overflow = true
                            throw IOException("$name does not fit in the queue")
                        }
                        sink.write(buffer, 0, read)
                    }
                }
            }
            val target = File(directory, name)
            if (!part.renameTo(target)) throw IOException("could not publish ${part.name}")
            Log.i(TAG, "Queued $name (${target.length()} bytes)")
            return Staged.Ok(Item(target, resolver.getType(uri) ?: mimeOf(name)))
        } catch (error: Exception) {
            Log.w(TAG, "Could not stage $uri", error)
            directory.deleteRecursively()
            return if (overflow) Staged.TooLarge(name) else Staged.Failed(name)
        }
    }

    /**
     * Drops staging directories that hold nothing but an unfinished copy, which
     * is what a share interrupted halfway leaves behind.
     */
    fun sweepIncomplete() {
        (root.listFiles() ?: emptyArray())
            .filter { it.isDirectory }
            .filter { directory ->
                directory.listFiles()?.none { it.isFile && !it.name.endsWith(PART_SUFFIX) } ?: true
            }
            .forEach {
                Log.i(TAG, "Dropping the interrupted staging directory ${it.name}")
                it.deleteRecursively()
            }
    }

    /** Drops the staged copy; the whole per file directory goes with it. */
    fun remove(item: Item) {
        val directory = item.file.parentFile
        if (directory != null && directory.parentFile == root) {
            directory.deleteRecursively()
        } else {
            item.file.delete()
        }
    }

    private fun displayName(uri: Uri): String? {
        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) return cursor.getString(0)
            }
        }.onFailure { Log.w(TAG, "Could not read the display name of $uri", it) }
        return uri.lastPathSegment
    }

    private fun mimeOf(name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase()
        if (extension.isEmpty()) return FALLBACK_MIME
        return runCatching { MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) }
            .getOrNull() ?: FALLBACK_MIME
    }

    companion object {
        private const val TAG = Prefs.TAG
        private const val DIRECTORY = "outbox"
        private const val PART_SUFFIX = ".part"
        private const val FALLBACK_MIME = "application/octet-stream"

        /** Total size the queue may hold while the Mac is unreachable. */
        const val QUEUE_LIMIT_BYTES = 512L * 1024 * 1024

        /**
         * Keeps a shared file name usable as a file name: no directories, no
         * `..`, no control characters, nothing absurdly long. Mirrors the
         * sanitizing the Mac does again on arrival.
         */
        fun sanitize(name: String?): String {
            val stripped = name.orEmpty().substringAfterLast('/').substringAfterLast('\\')
            var cleaned = stripped.filter { it.code >= 0x20 && it.code != 0x7F && it != ':' }.trim()
            while (cleaned.startsWith(".")) cleaned = cleaned.substring(1)
            cleaned = cleaned.trim()
            if (cleaned.isEmpty()) return "file"
            if (cleaned.length <= MAX_NAME_LENGTH) return cleaned

            val extension = cleaned.substringAfterLast('.', "")
            if (extension.isEmpty() || extension.length > 16) return cleaned.take(MAX_NAME_LENGTH)
            return cleaned.substringBeforeLast('.').take(MAX_NAME_LENGTH - extension.length - 1) +
                "." + extension
        }

        /** Lowercase hex SHA-256 of the whole file, the checksum sent in file-end. */
        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { stream ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = stream.read(buffer)
                    if (read < 0) break
                    digest.update(buffer, 0, read)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }

        private const val MAX_NAME_LENGTH = 200
    }
}

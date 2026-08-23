package pl.wojas.macdroidsync

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest

/** Metadata of one incoming file, taken from a file-offer message. */
data class FileOffer(val id: String, val name: String, val size: Long, val mime: String?)

/** Where an incoming file ends up. Mirrors the FileSink protocol on the Mac. */
interface FileSink {
    fun begin(offer: FileOffer)
    fun append(chunk: ByteArray)
    /** Publishes the file and describes where it landed. */
    fun finish(sha256: String?): IncomingFiles.Saved
    fun abort()
    val receivedBytes: Long
}

/**
 * Writes files coming from the Mac into the phone's public Download folder.
 *
 * On Android 10 and newer that goes through MediaStore, so no storage permission
 * is needed: the item is inserted as `IS_PENDING`, streamed into, and only
 * published once the SHA-256 from `file-end` matches. Anything else deletes it,
 * so a half transferred file never shows up in Files or the gallery. MediaStore
 * also takes care of name collisions on its own.
 *
 * On Android 9 there is no such API, so the legacy path writes `<name>.part`
 * next to the destination and renames it, which needs WRITE_EXTERNAL_STORAGE
 * (declared with maxSdkVersion 28).
 */
class IncomingFiles(private val context: Context) : FileSink {

    /** Where a finished file lives; [uri] is null only on the legacy path. */
    data class Saved(val displayName: String, val path: String, val uri: Uri?)

    private class Transfer(
        val offer: FileOffer,
        val safeName: String,
        val uri: Uri?,
        val legacyPart: File?,
        val stream: OutputStream,
        val digest: MessageDigest = MessageDigest.getInstance("SHA-256"),
        var received: Long = 0,
    )

    private val resolver = context.contentResolver

    @Volatile
    private var transfer: Transfer? = null

    override val receivedBytes: Long
        get() = transfer?.received ?: 0

    val activeName: String?
        get() = transfer?.offer?.name

    override fun begin(offer: FileOffer) {
        // A new offer supersedes anything left in flight.
        abort()

        if (offer.size > Wire.MAX_FILE_BYTES) {
            throw IOException("The file is larger than ${Wire.MAX_FILE_BYTES / (1024 * 1024)} MiB")
        }
        val safeName = Outbox.sanitize(offer.name)

        transfer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            beginMediaStore(offer, safeName)
        } else {
            beginLegacy(offer, safeName)
        }
        Log.i(TAG, "Receiving $safeName (${offer.size} bytes)")
    }

    override fun append(chunk: ByteArray) {
        val current = transfer ?: throw IOException("No file transfer is in progress")
        if (current.received + chunk.size > Wire.MAX_FILE_BYTES) {
            abort()
            throw IOException("The file is larger than announced")
        }
        try {
            current.stream.write(chunk)
        } catch (error: Exception) {
            abort()
            throw IOException("Could not write the file: ${error.message}")
        }
        current.digest.update(chunk)
        current.received += chunk.size
    }

    override fun finish(sha256: String?): Saved {
        val current = transfer ?: throw IOException("No file transfer is in progress")
        transfer = null
        runCatching { current.stream.flush() }
        runCatching { current.stream.close() }

        fun failed(message: String): IOException {
            discard(current)
            return IOException(message)
        }

        if (current.offer.size > 0 && current.offer.size != current.received) {
            throw failed("Expected ${current.offer.size} bytes but received ${current.received}")
        }
        val actual = current.digest.digest().joinToString("") { "%02x".format(it) }
        if (sha256 != null && !sha256.equals(actual, ignoreCase = true)) {
            throw failed("The checksum does not match, the file was corrupted in transit")
        }

        return try {
            publish(current)
        } catch (error: Exception) {
            throw failed("Could not save the file: ${error.message}")
        }
    }

    override fun abort() {
        val current = transfer ?: return
        transfer = null
        runCatching { current.stream.close() }
        discard(current)
        Log.i(TAG, "Discarded the partial transfer of ${current.safeName}")
    }

    // region MediaStore (Android 10+)

    private fun beginMediaStore(offer: FileOffer, safeName: String): Transfer {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, safeName)
            offer.mime?.takeIf { it.isNotBlank() }?.let { put(MediaStore.Downloads.MIME_TYPE, it) }
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values)
            ?: throw IOException("The Download folder is not writable")
        val stream = try {
            resolver.openOutputStream(uri) ?: throw IOException("no stream for $uri")
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw IOException("Could not open the destination: ${error.message}")
        }
        return Transfer(offer = offer, safeName = safeName, uri = uri, legacyPart = null, stream = stream)
    }

    // endregion

    // region Legacy (Android 9)

    private fun beginLegacy(offer: FileOffer, safeName: String): Transfer {
        @Suppress("DEPRECATION")
        val directory = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IOException("The Download folder is not writable")
        }
        val part = File(directory, "$safeName.part")
        val stream = try {
            part.outputStream()
        } catch (error: Exception) {
            throw IOException("Could not open the destination: ${error.message}")
        }
        return Transfer(offer = offer, safeName = safeName, uri = null, legacyPart = part, stream = stream)
    }

    /** `photo.jpg` becomes `photo (2).jpg`, the same rule the Mac side uses. */
    private fun uniqueLegacyFile(directory: File, name: String): File {
        var candidate = File(directory, name)
        if (!candidate.exists()) return candidate
        val base = name.substringBeforeLast('.', name)
        val extension = name.substringAfterLast('.', "")
        var index = 2
        while (candidate.exists() && index < 10_000) {
            val suffixed = if (extension.isEmpty()) "$base ($index)" else "$base ($index).$extension"
            candidate = File(directory, suffixed)
            index++
        }
        return candidate
    }

    // endregion

    private fun publish(current: Transfer): Saved {
        current.uri?.let { uri ->
            val values = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
            resolver.update(uri, values, null, null)
            // MediaStore may have renamed the file to avoid a collision.
            val finalName = displayName(uri) ?: current.safeName
            Log.i(TAG, "Saved Download/$finalName (${current.received} bytes)")
            return Saved(displayName = finalName, path = "Download/$finalName", uri = uri)
        }

        val part = current.legacyPart ?: throw IOException("nowhere to publish the file")
        val destination = uniqueLegacyFile(part.parentFile!!, current.safeName)
        if (!part.renameTo(destination)) throw IOException("could not rename ${part.name}")
        Log.i(TAG, "Saved ${destination.absolutePath} (${current.received} bytes)")
        return Saved(displayName = destination.name, path = destination.absolutePath, uri = null)
    }

    private fun discard(current: Transfer) {
        current.uri?.let { runCatching { resolver.delete(it, null, null) } }
        current.legacyPart?.let { runCatching { it.delete() } }
    }

    private fun displayName(uri: Uri): String? {
        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) return cursor.getString(0)
            }
        }
        return null
    }

    companion object {
        private const val TAG = Prefs.TAG
    }
}

package pl.wojas.macdroidsync

import android.content.Context
import android.util.Log
import java.io.File

/**
 * The phone's own record of its camera folder: a hash cache so that 46 GB is not
 * read again every cycle, and the list a disappearance is noticed against.
 *
 * A file rather than a database, like every other store in this project, and
 * logic free on purpose - [PhotoLedgerCodec] does the parsing, and that is what
 * the tests exercise. Written whole, through a temporary file and a rename, so a
 * process killed mid write leaves either the old ledger or a file whose last line
 * is truncated. The codec is built to survive the second case.
 */
class PhotoLedger(context: Context) {

    private val file = File(context.filesDir, "photo-ledger.tsv")
    private var rows: MutableMap<String, PhotoLedgerRow> = load()

    val keys: Set<String> get() = rows.keys

    fun row(key: String): PhotoLedgerRow? = rows[key]

    fun put(row: PhotoLedgerRow) {
        rows[row.key] = row
    }

    fun remove(keys: Collection<String>) {
        keys.forEach { rows.remove(it) }
    }

    /**
     * Marks an attempt that came to nothing. Deliberately not a removal: a row
     * that disappears from the ledger becomes a tombstone, which would tell the
     * Mac to take the photo out of the library - so giving up on a transfer must
     * never look like the file having been deleted.
     */
    fun recordFailure(key: String, reason: PhotoExclusion? = null) {
        val row = rows[key] ?: return
        rows[key] = row.copy(attempts = row.attempts + 1, skipReason = reason ?: row.skipReason)
    }

    fun save() {
        try {
            val temporary = File(file.parentFile, "${file.name}.part")
            temporary.writeText(PhotoLedgerCodec.encode(rows.values))
            if (!temporary.renameTo(file)) {
                temporary.copyTo(file, overwrite = true)
                temporary.delete()
            }
        } catch (error: Exception) {
            Log.w(TAG, "Could not save the photo ledger", error)
        }
    }

    private fun load(): MutableMap<String, PhotoLedgerRow> {
        if (!file.exists()) return mutableMapOf()
        return try {
            PhotoLedgerCodec.decode(file.readText())
                .associateBy { it.key }
                .toMutableMap()
        } catch (error: Exception) {
            Log.w(TAG, "The photo ledger is unreadable; starting a new one", error)
            mutableMapOf()
        }
    }

    private companion object {
        private const val TAG = Prefs.TAG
    }
}

package pl.wojas.macdroidsync

import android.content.Context
import android.util.Log
import java.security.MessageDigest
import java.util.UUID

/**
 * One photo sync cycle, from the phone's side.
 *
 * The phone owns the window and the interval, because it is the side that can
 * cheaply tell whether anything changed at all; the Mac owns what to do about it.
 * So this class describes and sends, and never decides what the gallery should
 * look like.
 *
 * Everything it decides for itself is in PhotoSync.kt and is tested there. What
 * lives here is the order of the steps and the budget.
 */
class PhotoSyncEngine(
    private val context: Context,
    private val prefs: Prefs,
    private val scanner: PhotoScanner = PhotoScanner(context),
    private val ledger: PhotoLedger = PhotoLedger(context),
) {

    /** How much hashing one cycle may do before it starts sending items unhashed. */
    private val hashBudgetBytes = 1L * 1024 * 1024 * 1024

    /** The manifest this phone last described, so a stale pull can be recognised. */
    private var manifestId: String? = null
    private var describedRows: Map<String, PhotoScanner.Row> = emptyMap()

    /**
     * Describes the camera folder to the Mac, in pages.
     *
     * A refusal - no permission, a partial grant, an unreadable folder - is sent
     * as one message with `ok: false` and no items at all. It must never be sent
     * as an empty manifest, because an empty manifest is how the Mac is told that
     * everything was deleted.
     */
    fun describe(connection: PeerConnection) {
        val scan = scanner.scan()
        if (!scan.complete) {
            Log.i(TAG, "Not describing the camera folder: ${scan.refusal}")
            connection.sendPhotoManifest(PhotoPayload(), ok = false, reason = scan.refusal)
            return
        }

        val now = System.currentTimeMillis()
        val from = PhotoWindow.effectiveFrom(prefs.photoStartDate, prefs.photoLastDays, now)
        val id = "${prefs.deviceId}:$now"
        manifestId = id

        // The tombstones come from the *unwindowed* scan: a photo deleted from
        // last year has to be reported too, and it is long outside the window.
        val present = scan.rows.map { it.key }
        val gone = PhotoTombstones.goneKeys(ledger.keys, present, scan.complete)
        ledger.remove(gone)

        val inWindow = scan.rows.filter { PhotoWindow.contains(it.captureAt, from) }
        val skippedWithoutDate = scan.rows.count { it.captureAt <= 0 }
        val items = describe(inWindow)
        describedRows = inWindow.associateBy { it.key }
        ledger.save()

        val pages = PhotoManifestPager.paginate(
            items,
            perPage = Wire.PHOTO_MANIFEST_PAGE_ITEMS,
            maxBytes = Wire.PHOTO_MANIFEST_PAGE_BYTES,
        )
        Log.i(
            TAG,
            "Describing ${items.size} item(s) in ${pages.size} page(s), " +
                "${gone.size} gone, $skippedWithoutDate without a date",
        )
        for (page in pages) {
            connection.sendPhotoManifest(
                PhotoPayload(
                    manifestId = id,
                    page = page.page,
                    pages = page.pages,
                    count = page.count,
                    from = from,
                    items = page.items,
                    // Tombstones ride on the first page; repeating them on every
                    // page would have the Mac see each of them several times.
                    gone = if (page.page == 1 && gone.isNotEmpty()) gone else null,
                    skipped = if (page.page == pages.size) skippedWithoutDate else null,
                ),
            )
        }
    }

    /**
     * Turns rows into manifest items, hashing what has to be hashed and marking
     * what cannot be sent.
     *
     * An item that is excluded is still listed, with the reason: leaving it out
     * would read as a deletion, and a 2 GB video is not a deletion.
     */
    private fun describe(rows: List<PhotoScanner.Row>): List<PhotoItem> {
        var hashed = 0L
        val maxItemBytes = prefs.photoMaxItemBytes
        return rows.sortedByDescending { it.captureAt }.map { row ->
            val cached = ledger.row(row.key)
            val exclusion = when {
                row.size > maxItemBytes -> PhotoExclusion.SIZE
                cached?.skipReason == PhotoExclusion.UNREADABLE && cached.attempts >= MAX_ATTEMPTS ->
                    PhotoExclusion.UNREADABLE
                else -> null
            }
            var sha = cached?.sha256
            if (exclusion == null && PhotoHashPolicy.needsHash(cached, row.size, row.dateModified, row.generation)) {
                if (hashed + row.size <= hashBudgetBytes) {
                    sha = hash(row)
                    hashed += row.size
                } else {
                    // Out of budget for this cycle: the item goes out without a
                    // hash, which the Mac reads as "compare size and time
                    // instead". Progress, never a wrong answer.
                    sha = null
                }
            }
            ledger.put(
                PhotoLedgerRow(
                    key = row.key,
                    size = row.size,
                    captureAt = row.captureAt,
                    dateModified = row.dateModified,
                    generation = row.generation,
                    mediaStoreId = row.id,
                    sha256 = sha,
                    attempts = cached?.attempts ?: 0,
                    skipReason = exclusion,
                ),
            )
            PhotoItem(
                key = row.key,
                captureAt = row.captureAt,
                size = row.size,
                mime = row.mime,
                sha256 = sha,
                excluded = exclusion,
            )
        }
    }

    private fun hash(row: PhotoScanner.Row): String? {
        val stream = scanner.openOriginal(row) ?: return null
        return try {
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(64 * 1024)
            stream.use {
                while (true) {
                    val read = it.read(buffer)
                    if (read < 0) break
                    digest.update(buffer, 0, read)
                }
            }
            digest.digest().joinToString("") { "%02x".format(it) }
        } catch (error: Exception) {
            Log.w(TAG, "Could not hash ${row.name}", error)
            null
        }
    }

    /**
     * Sends the batch the Mac asked for, one item at a time.
     *
     * Returns the keys that could not be sent, so the caller can report them. A
     * failure marks the ledger row; it never removes it, because a removed row
     * becomes a tombstone and would tell the Mac to delete the photo.
     */
    suspend fun send(
        connection: PeerConnection,
        keys: List<String>,
        awaitAck: suspend (String, String) -> Boolean,
        onProgress: (String, Long, Long) -> Unit,
    ): List<String> {
        val failures = mutableListOf<String>()
        for (key in keys) {
            val row = describedRows[key] ?: ledgerRowAsScanRow(key)
            if (row == null) {
                Log.i(TAG, "The Mac asked for $key, which this phone no longer has")
                connection.sendPhotoManifest(PhotoPayload(page = 0, gone = listOf(key)))
                continue
            }
            val size = scanner.currentSize(row) ?: row.size
            if (size > prefs.photoMaxItemBytes) {
                failures.add(key)
                ledger.recordFailure(key, PhotoExclusion.SIZE)
                continue
            }
            val stream = scanner.openOriginal(row)
            if (stream == null) {
                // Either the file went away or the original bytes are not
                // available, which would mean sending it without its location.
                failures.add(key)
                ledger.recordFailure(key, PhotoExclusion.NO_LOCATION)
                continue
            }
            stream.close()

            val fileId = UUID.randomUUID().toString()
            val sent = try {
                connection.sendPhoto(
                    key = key,
                    name = row.name,
                    size = size,
                    mime = row.mime,
                    captureAt = row.captureAt,
                    fileId = fileId,
                    open = { scanner.openOriginal(row) ?: throw IllegalStateException("gone") },
                    onProgress = { done, total -> onProgress(row.name, done, total) },
                )
            } catch (error: Exception) {
                Log.w(TAG, "Could not send ${row.name}", error)
                false
            }
            if (!sent || !awaitAck(fileId, row.name)) {
                failures.add(key)
                ledger.recordFailure(key)
            }
        }
        ledger.save()
        return failures
    }

    /** A key the Mac asked for that was described in an earlier cycle. */
    private fun ledgerRowAsScanRow(key: String): PhotoScanner.Row? {
        val row = ledger.row(key) ?: return null
        return PhotoScanner.Row(
            key = row.key,
            id = row.mediaStoreId,
            name = key.substringAfterLast('/'),
            size = row.size,
            mime = null,
            captureAt = row.captureAt,
            dateModified = row.dateModified,
            generation = row.generation,
            isVideo = key.substringAfterLast('.', "").lowercase() in VIDEO_EXTENSIONS,
        )
    }

    private companion object {
        private const val TAG = Prefs.TAG
        private const val MAX_ATTEMPTS = 3
        private val VIDEO_EXTENSIONS = setOf("mp4", "mov", "3gp", "mkv", "webm", "m4v")
    }
}

package pl.wojas.macdroidsync

import org.json.JSONArray
import org.json.JSONObject

/**
 * The photo sync, as data and as pure functions.
 *
 * Nothing here touches Context, ContentResolver or MediaStore: that lives in
 * PhotoScanner, deliberately kept logic free. The reason is the test setup - the
 * project has plain JUnit with no Robolectric, so only pure Kotlin runs under
 * test, and the decisions that can lose photos have to be exactly the testable
 * part.
 *
 * The wire shape mirrors PhotoSync.swift key for key; PROTOCOL.md section 8 and
 * the vectors in section 6 are what keep the two honest.
 */

/** Why an item is listed but will never be sent. */
enum class PhotoExclusion(val wire: String) {
    /** Bigger than the agreed per item limit. */
    SIZE("size"),

    /** MediaStore would not open it. */
    UNREADABLE("unreadable"),

    /**
     * The original bytes are not available, so the GPS tags would be stripped on
     * the way out. Sending it would lose data without saying so.
     */
    NO_LOCATION("noLocation"),

    /** No capture date could be established, so it belongs to no window. */
    NO_DATE("noDate");

    companion object {
        fun of(wire: String?): PhotoExclusion? = entries.firstOrNull { it.wire == wire }
    }
}

/**
 * One item of one manifest page. Single letter keys because a full camera folder
 * sends five thousand copies of this object.
 */
data class PhotoItem(
    val key: String,
    /** Capture time in milliseconds, never a modification time. */
    val captureAt: Long,
    val size: Long,
    val mime: String? = null,
    /** Lowercase hex, absent when the hashing budget ran out. */
    val sha256: String? = null,
    val excluded: PhotoExclusion? = null,
) {
    fun toJson(): JSONObject {
        val json = JSONObject()
        json.put("k", key)
        json.put("t", captureAt)
        json.put("s", size)
        mime?.let { json.put("m", it) }
        sha256?.let { json.put("h", it) }
        excluded?.let { json.put("x", it.wire) }
        return json
    }

    companion object {
        fun fromJson(json: JSONObject): PhotoItem = PhotoItem(
            key = json.optString("k"),
            captureAt = json.optLong("t"),
            size = json.optLong("s"),
            mime = json.optStringOrNull("m"),
            sha256 = json.optStringOrNull("h"),
            excluded = PhotoExclusion.of(json.optStringOrNull("x")),
        )

        private fun JSONObject.optStringOrNull(key: String): String? =
            if (has(key) && !isNull(key)) optString(key) else null
    }
}

/** The `photo` field of a message. */
data class PhotoPayload(
    val key: String? = null,
    val manifestId: String? = null,
    val page: Int? = null,
    val pages: Int? = null,
    val count: Int? = null,
    /** The window bound this phone applied. The Mac uses this and never its own. */
    val from: Long? = null,
    /**
     * On file-offer: when this one item was taken. Not the same thing as [from],
     * which bounds a whole manifest; the Mac's index needs the item's own time
     * because that is what scopes deletions later.
     */
    val captureAt: Long? = null,
    val items: List<PhotoItem>? = null,
    /** Keys known to be gone. Not bounded by the window. */
    val gone: List<String>? = null,
    /** On photo-pull: what to send. Absent means "build a manifest now". */
    val keys: List<String>? = null,
    val skipped: Int? = null,
) {
    fun toJson(): JSONObject {
        val json = JSONObject()
        key?.let { json.put("key", it) }
        manifestId?.let { json.put("manifestId", it) }
        page?.let { json.put("page", it) }
        pages?.let { json.put("pages", it) }
        count?.let { json.put("count", it) }
        from?.let { json.put("from", it) }
        captureAt?.let { json.put("captureAt", it) }
        items?.let { list -> json.put("items", JSONArray().apply { list.forEach { put(it.toJson()) } }) }
        gone?.let { list -> json.put("gone", JSONArray(list)) }
        keys?.let { list -> json.put("keys", JSONArray(list)) }
        skipped?.let { json.put("skipped", it) }
        return json
    }

    companion object {
        fun fromJson(json: JSONObject): PhotoPayload = PhotoPayload(
            key = json.stringOrNull("key"),
            manifestId = json.stringOrNull("manifestId"),
            page = if (json.has("page")) json.optInt("page") else null,
            pages = if (json.has("pages")) json.optInt("pages") else null,
            count = if (json.has("count")) json.optInt("count") else null,
            from = if (json.has("from")) json.optLong("from") else null,
            captureAt = if (json.has("captureAt")) json.optLong("captureAt") else null,
            items = json.optJSONArray("items")?.let { array ->
                (0 until array.length()).map { PhotoItem.fromJson(array.getJSONObject(it)) }
            },
            gone = json.optJSONArray("gone")?.strings(),
            keys = json.optJSONArray("keys")?.strings(),
            skipped = if (json.has("skipped")) json.optInt("skipped") else null,
        )

        private fun JSONObject.stringOrNull(key: String): String? =
            if (has(key) && !isNull(key)) optString(key) else null

        private fun JSONArray.strings(): List<String> =
            (0 until length()).map { optString(it) }
    }
}

/**
 * How a photo is addressed. The relative path plus the file name, so it survives
 * the thing MediaStore ids do not: a restore, which mints fresh ids and would
 * make an entire library look new.
 */
object PhotoKey {

    /** The one folder this feature reads. */
    const val CAMERA_PATH = "DCIM/Camera/"

    /**
     * Builds a key, or null when the row cannot be addressed safely. MediaStore
     * hands back a relative path that already ends in a slash, but nothing about
     * that is guaranteed, so the shape is normalised here rather than assumed.
     */
    fun of(relativePath: String?, displayName: String?): String? {
        val name = displayName?.trim().orEmpty()
        if (name.isEmpty() || name.contains('/') || name == "." || name == "..") return null
        val path = (relativePath ?: CAMERA_PATH)
            .trim()
            .removePrefix("./")
            .trimStart('/')
            .replace(Regex("/{2,}"), "/")
        if (path.split('/').any { it == ".." }) return null
        val folder = if (path.isEmpty() || path.endsWith("/")) path else "$path/"
        return folder + name
    }
}

/** The two lower bounds of the window, and which of them wins. */
object PhotoWindow {

    /**
     * The effective lower bound in milliseconds. Both settings say "nothing
     * older than this", so the stricter - the later - of the two applies. That
     * is what makes the day count a fuse: a start date in 2005 cannot on its own
     * put the whole library in the window.
     */
    fun effectiveFrom(startDateMillis: Long, lastDays: Int, nowMillis: Long): Long {
        val days = if (lastDays < 1) 1 else lastDays
        val byDays = nowMillis - days * 86_400_000L
        return maxOf(byDays, startDateMillis)
    }

    fun contains(captureAt: Long, from: Long): Boolean = captureAt > 0 && captureAt >= from
}

/**
 * When a photo was taken. A ladder rather than one column, because the answer
 * decides what is in the window and a wrong answer moves gigabytes.
 *
 * `DATE_MODIFIED` is deliberately not part of the ladder. It answers a different
 * question: copying or rewriting a file refreshes it, so a photo from last year
 * would re enter the window and be sent a second time.
 */
object PhotoCaptureDate {

    /** Names like 20260119_184146.jpg, IMG_20260119_184146.jpg, PXL_20260119_184146123.jpg. */
    private val COMPACT = Regex("(?:^|[^0-9])(20\\d{2})(\\d{2})(\\d{2})[_-]?(\\d{2})(\\d{2})(\\d{2})")

    /** Names like Screenshot_2024-01-01-12-00-00.png. */
    private val DASHED = Regex("(20\\d{2})-(\\d{2})-(\\d{2})[-_ ](\\d{2})[-:.]?(\\d{2})[-:.]?(\\d{2})")

    /**
     * Resolves the capture time, or 0 when it cannot be established. Zero is not
     * a fallback date, it means "outside every window": such an item is never
     * manifested, never fetched, and - because 0 is below any bound - never a
     * deletion candidate either. Skipping is recoverable; a stampede is not.
     */
    fun resolve(dateTaken: Long?, displayName: String?, zoneOffsetMillis: Int): Long {
        if (dateTaken != null && dateTaken > 0) return dateTaken
        val name = displayName ?: return 0
        val match = COMPACT.find(name) ?: DASHED.find(name) ?: return 0
        val (year, month, day, hour, minute, second) = match.destructured
        return utcMillis(
            year.toInt(), month.toInt(), day.toInt(),
            hour.toInt(), minute.toInt(), second.toInt(),
        ) - zoneOffsetMillis
    }

    private fun utcMillis(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int): Long =
        CivilDate.utcMillis(year, month, day, hour, minute, second)
}

/**
 * Calendar arithmetic, done by hand.
 *
 * No java.time and no Calendar on purpose: this has to give the same answer under
 * a plain JVM test as on the phone, whatever the default time zone happens to be,
 * and both of those types read ambient state.
 */
object CivilDate {

    /** Midnight-based milliseconds, or 0 when the date does not exist. */
    fun utcMillis(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int): Long {
        if (year < 1970 || month !in 1..12 || day < 1 || hour > 23 || minute > 59 || second > 59) return 0
        val lengths = monthLengths(year)
        if (day > lengths[month - 1]) return 0
        var days = 0L
        for (y in 1970 until year) days += if (isLeap(y)) 366 else 365
        for (m in 0 until month - 1) days += lengths[m]
        days += (day - 1)
        return ((days * 24 + hour) * 60 + minute) * 60_000L + second * 1_000L
    }

    /** `YYYY-MM-DD` of a moment, the inverse of the above at midnight. */
    fun text(millis: Long): String {
        var days = millis / 86_400_000L
        var year = 1970
        while (true) {
            val length = if (isLeap(year)) 366 else 365
            if (days < length) break
            days -= length
            year++
        }
        val lengths = monthLengths(year)
        var month = 0
        while (month < 12 && days >= lengths[month]) {
            days -= lengths[month]
            month++
        }
        return "%04d-%02d-%02d".format(year, month + 1, days + 1)
    }

    private fun monthLengths(year: Int) =
        intArrayOf(31, if (isLeap(year)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)

    private fun isLeap(year: Int): Boolean =
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

/**
 * One row of the phone's ledger: what is known about a file so it does not have
 * to be hashed again, and so that its disappearance can be reported.
 */
data class PhotoLedgerRow(
    val key: String,
    val size: Long,
    val captureAt: Long,
    val dateModified: Long,
    /** MediaStore's GENERATION_MODIFIED, or 0 below API 30 where it does not exist. */
    val generation: Long,
    val mediaStoreId: Long,
    val sha256: String? = null,
    val attempts: Int = 0,
    val skipReason: PhotoExclusion? = null,
)

/**
 * The ledger on disk, as text.
 *
 * A tab separated file rather than SQLite, for the same reason every other store
 * in this project is a file: a database would drag every test into needing a
 * Context. Writing is expected to be atomic (write a temporary file, rename), so
 * the one failure this has to tolerate is a truncated final line from a process
 * killed mid write.
 */
object PhotoLedgerCodec {

    private const val VERSION_LINE = "macdroidsync-photo-ledger 1"
    private const val COLUMNS = 9

    fun encode(rows: Collection<PhotoLedgerRow>): String {
        val text = StringBuilder(VERSION_LINE).append('\n')
        for (row in rows.sortedBy { it.key }) {
            text.append(escape(row.key)).append('\t')
                .append(row.size).append('\t')
                .append(row.captureAt).append('\t')
                .append(row.dateModified).append('\t')
                .append(row.generation).append('\t')
                .append(row.mediaStoreId).append('\t')
                .append(row.sha256 ?: "").append('\t')
                .append(row.attempts).append('\t')
                .append(row.skipReason?.wire ?: "").append('\n')
        }
        return text.toString()
    }

    /**
     * Reads what is readable and drops what is not. A row that cannot be parsed
     * is skipped rather than fatal: the cost of dropping it is one file hashed
     * again, while refusing the whole ledger would erase every tombstone the
     * phone owes the Mac.
     */
    fun decode(text: String): List<PhotoLedgerRow> {
        val rows = mutableListOf<PhotoLedgerRow>()
        for ((index, line) in text.lineSequence().withIndex()) {
            if (index == 0 || line.isEmpty()) continue
            val parts = line.split('\t')
            if (parts.size < COLUMNS) continue
            val key = unescape(parts[0])
            if (key.isEmpty()) continue
            val size = parts[1].toLongOrNull() ?: continue
            val captureAt = parts[2].toLongOrNull() ?: continue
            val dateModified = parts[3].toLongOrNull() ?: continue
            val generation = parts[4].toLongOrNull() ?: continue
            val mediaStoreId = parts[5].toLongOrNull() ?: continue
            rows.add(
                PhotoLedgerRow(
                    key = key,
                    size = size,
                    captureAt = captureAt,
                    dateModified = dateModified,
                    generation = generation,
                    mediaStoreId = mediaStoreId,
                    sha256 = parts[6].ifEmpty { null },
                    attempts = parts[7].toIntOrNull() ?: 0,
                    skipReason = PhotoExclusion.of(parts[8].ifEmpty { null }),
                ),
            )
        }
        return rows
    }

    private fun escape(value: String): String =
        value.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")

    private fun unescape(value: String): String {
        val out = StringBuilder(value.length)
        var index = 0
        while (index < value.length) {
            val character = value[index]
            if (character == '\\' && index + 1 < value.length) {
                when (value[index + 1]) {
                    't' -> { out.append('\t'); index += 2 }
                    'n' -> { out.append('\n'); index += 2 }
                    '\\' -> { out.append('\\'); index += 2 }
                    else -> { out.append(character); index++ }
                }
            } else {
                out.append(character)
                index++
            }
        }
        return out.toString()
    }
}

/**
 * When a file has to be hashed again.
 *
 * Hashing is the expensive part of a cycle - the camera folder here is 46 GB -
 * so a hash is computed once per file and kept. What it must never be used for
 * is deciding window membership: that is metadata only.
 */
object PhotoHashPolicy {

    /**
     * True when the cached hash cannot be trusted for this file. Any of the
     * cheap signals moving is enough; `GENERATION_MODIFIED` is the strongest,
     * because MediaStore bumps it on any write, but it only exists from API 30.
     */
    fun needsHash(cached: PhotoLedgerRow?, size: Long, dateModified: Long, generation: Long): Boolean {
        if (cached?.sha256 == null) return true
        if (cached.size != size) return true
        if (cached.dateModified != dateModified) return true
        // A generation of zero means "this Android does not report it", which is
        // not a change - treating it as one would rehash the library every cycle.
        if (generation > 0 && cached.generation != generation) return true
        return false
    }
}

/**
 * What the phone asserts is gone.
 *
 * Tombstones are the only way a deletion outside the sync window can reach the
 * Mac, and they are an assertion rather than an inference - which is why the
 * scan has to be trustworthy before any of them may be sent.
 */
object PhotoTombstones {

    /**
     * Keys in the ledger that the scan no longer sees.
     *
     * The scan is compared **unwindowed** on purpose: a photo from last year that
     * was deleted has to be reported even though it is long out of the window.
     *
     * When the scan could not be trusted - a missing or partial media permission,
     * a MediaStore that threw, a camera folder that is suddenly not there - the
     * answer is an empty list, never "everything vanished". That case looks
     * exactly like a mass deletion, and this is the guard for it.
     */
    fun goneKeys(ledger: Collection<String>, present: Collection<String>, scanComplete: Boolean): List<String> {
        if (!scanComplete) return emptyList()
        val seen = present.toHashSet()
        return ledger.filterNot { seen.contains(it) }.sorted()
    }
}

/**
 * The start date, as the settings screen writes it and reads it back.
 *
 * A plain `YYYY-MM-DD` field rather than a date picker, because this is a value
 * that is typed once and then left alone - and because a pure parser can be
 * tested, which a dialog cannot.
 */
object PhotoDate {

    private val PATTERN = Regex("^(\\d{4})-(\\d{2})-(\\d{2})$")

    /** Midnight local time on that day, or null when the text is not a date. */
    fun parse(text: String?, zoneOffsetMillis: Int): Long? {
        val match = PATTERN.find(text?.trim().orEmpty()) ?: return null
        val (year, month, day) = match.destructured
        val utc = CivilDate.utcMillis(year.toInt(), month.toInt(), day.toInt(), 0, 0, 0)
        if (utc <= 0) return null
        return utc - zoneOffsetMillis
    }

    /** The other direction, for showing what is stored. Empty when nothing is. */
    fun format(millis: Long, zoneOffsetMillis: Int): String {
        if (millis <= 0) return ""
        return CivilDate.text(millis + zoneOffsetMillis)
    }
}

/** Cuts a manifest into pages that fit a frame, and numbers them. */
object PhotoManifestPager {

    data class Page(
        val page: Int,
        val pages: Int,
        val count: Int,
        val items: List<PhotoItem>,
    )

    /**
     * Splits by item count and by encoded size, whichever runs out first. The
     * count in every page header is the total across all pages: that number is
     * what lets the Mac tell a complete snapshot from a truncated one, so it is
     * never the size of one page.
     */
    fun paginate(
        items: List<PhotoItem>,
        perPage: Int = 500,
        maxBytes: Int = 512 * 1024,
    ): List<Page> {
        if (items.isEmpty()) return listOf(Page(page = 1, pages = 1, count = 0, items = emptyList()))
        val limit = if (perPage < 1) 1 else perPage
        val chunks = mutableListOf<MutableList<PhotoItem>>()
        var current = mutableListOf<PhotoItem>()
        var bytes = 0
        for (item in items) {
            val itemBytes = item.toJson().toString().toByteArray(Charsets.UTF_8).size + 1
            val full = current.size >= limit || (current.isNotEmpty() && bytes + itemBytes > maxBytes)
            if (full) {
                chunks.add(current)
                current = mutableListOf()
                bytes = 0
            }
            current.add(item)
            bytes += itemBytes
        }
        if (current.isNotEmpty()) chunks.add(current)
        return chunks.mapIndexed { index, chunk ->
            Page(page = index + 1, pages = chunks.size, count = items.size, items = chunk)
        }
    }
}

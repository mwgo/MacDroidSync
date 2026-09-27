package pl.wojas.macdroidsync

import android.content.ContentResolver
import android.content.Context
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.ContactsContract
import android.provider.Telephony
import android.util.Log
import java.io.ByteArrayOutputStream

/**
 * The only place on the phone that reads the messaging database. It reads
 * columns and nothing else; paging, snippets and status words are in [SmsRules].
 *
 * Every public call assumes READ_SMS is granted and throws when it is not, so
 * the caller turns that into a reason for the Mac.
 */
class SmsReader(private val context: Context) {

    private val resolver: ContentResolver = context.contentResolver

    /**
     * Contacts looked up this session, keyed by the address as the database
     * spells it; [NO_CONTACT] records "none". Requests arrive on several threads.
     */
    private val contacts = java.util.concurrent.ConcurrentHashMap<String, Contact>()

    /** The newest conversations first, at most [SmsRules.MAX_THREADS]. */
    fun threads(): List<SmsThread> {
        val unread = unreadCounts()
        val rows = runCatching { conversations() }
            .onFailure { Log.w(TAG, "Conversation list failed, reading the tables instead", it) }
            .getOrNull()
            ?: conversationsFromTables()
        return rows.map { row ->
            row.copy(
                snippet = row.snippet ?: latestText(row.id),
                name = displayName(row.addresses),
                photo = photoOf(row.addresses),
                unread = unread[row.id] ?: 0,
            )
        }
    }

    /**
     * One page of a conversation, oldest first. [after] and [before] are
     * milliseconds, exclusive; both absent means the newest page.
     */
    fun messages(threadId: Long, after: Long?, before: Long?, limit: Int): Pair<List<SmsMessage>, Boolean> {
        val sms = smsMessages(threadId, after, before, limit + 1)
        val mms = runCatching { mmsMessages(threadId, after, before, limit + 1) }
            .onFailure { Log.w(TAG, "MMS of thread $threadId could not be read", it) }
            .getOrDefault(emptyList())
        return SmsRules.page(sms, mms, limit)
    }

    /**
     * The provider gives no snippet when the newest message is an MMS, so its
     * text is read here; a picture alone stays without one.
     */
    private fun latestText(threadId: Long): String? = runCatching {
        SmsRules.snippet(messages(threadId, after = null, before = null, limit = 1).first.lastOrNull()?.text)
    }.getOrNull()

    /** The highest row ids of received messages, where [newSince] starts counting. */
    fun inboxMarks(): Pair<Long, Long> =
        maxId(Telephony.Sms.Inbox.CONTENT_URI) to runCatching { maxId(Telephony.Mms.Inbox.CONTENT_URI) }.getOrDefault(0L)

    /**
     * Received messages with row ids above [marks], grouped by conversation, and
     * the new marks. This is what becomes a notification on the Mac.
     */
    fun newSince(marks: Pair<Long, Long>): Pair<Map<Long, List<SmsMessage>>, Pair<Long, Long>> {
        val found = mutableMapOf<Long, MutableList<SmsMessage>>()
        var smsMark = marks.first
        var mmsMark = marks.second
        resolver.query(
            Telephony.Sms.Inbox.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.THREAD_ID, Telephony.Sms.DATE, Telephony.Sms.BODY, Telephony.Sms.ADDRESS),
            "${Telephony.Sms._ID} > ?",
            arrayOf(marks.first.toString()),
            "${Telephony.Sms._ID} ASC",
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(0)
                smsMark = maxOf(smsMark, id)
                found.getOrPut(cursor.getLong(1)) { mutableListOf() } += SmsMessage(
                    id = "s$id",
                    date = cursor.getLong(2),
                    fromMe = false,
                    text = cursor.getStringOrNull(3),
                    address = cursor.getStringOrNull(4),
                )
            }
        }
        runCatching {
            resolver.query(
                Telephony.Mms.Inbox.CONTENT_URI,
                arrayOf(Telephony.Mms._ID, Telephony.Mms.THREAD_ID, Telephony.Mms.DATE),
                "${Telephony.Mms._ID} > ?",
                arrayOf(marks.second.toString()),
                "${Telephony.Mms._ID} ASC",
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(0)
                    mmsMark = maxOf(mmsMark, id)
                    found.getOrPut(cursor.getLong(1)) { mutableListOf() } +=
                        mmsMessage(id, cursor.getLong(2) * 1000, box = 1)
                }
            }
        }.onFailure { Log.w(TAG, "New MMS could not be read", it) }
        return found to (smsMark to mmsMark)
    }

    /**
     * Received messages still unread on this phone, newer than [sinceMs], at
     * most [limit] of them, newest kept, grouped by conversation. What the Mac
     * is told about when a session starts, so a message that came in while it
     * was away still gets its notification.
     */
    fun unread(sinceMs: Long, limit: Int): Map<Long, List<SmsMessage>> {
        val found = mutableListOf<Pair<Long, SmsMessage>>()
        resolver.query(
            Telephony.Sms.Inbox.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.THREAD_ID, Telephony.Sms.DATE, Telephony.Sms.BODY, Telephony.Sms.ADDRESS),
            "${Telephony.Sms.READ} = 0 AND ${Telephony.Sms.DATE} > ?",
            arrayOf(sinceMs.toString()),
            "${Telephony.Sms.DATE} DESC",
        )?.use { cursor ->
            while (cursor.moveToNext() && found.size < limit) {
                found += cursor.getLong(1) to SmsMessage(
                    id = "s${cursor.getLong(0)}",
                    date = cursor.getLong(2),
                    fromMe = false,
                    text = cursor.getStringOrNull(3),
                    address = cursor.getStringOrNull(4),
                )
            }
        }
        runCatching {
            resolver.query(
                Telephony.Mms.Inbox.CONTENT_URI,
                arrayOf(Telephony.Mms._ID, Telephony.Mms.THREAD_ID, Telephony.Mms.DATE),
                "${Telephony.Mms.READ} = 0 AND ${Telephony.Mms.DATE} > ?",
                arrayOf((sinceMs / 1000).toString()),
                "${Telephony.Mms.DATE} DESC",
            )?.use { cursor ->
                var taken = 0
                while (cursor.moveToNext() && taken < limit) {
                    found += cursor.getLong(1) to mmsMessage(cursor.getLong(0), cursor.getLong(2) * 1000, box = 1)
                    taken++
                }
            }
        }.onFailure { Log.w(TAG, "Unread MMS could not be read", it) }
        return found
            .sortedByDescending { it.second.date }
            .take(limit)
            .groupBy({ it.first }, { it.second })
            .mapValues { (_, messages) -> messages.sortedBy { it.date } }
    }

    /**
     * One MMS picture as a JPEG, no side longer than [maxPixel]. Null when the
     * part is gone or is not a picture.
     */
    fun image(partId: String, maxPixel: Int = SmsRules.MAX_IMAGE_PIXEL): ByteArray? {
        val id = partId.toLongOrNull() ?: return null
        val uri = Uri.parse("content://mms/part/$id")
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxPixel) sample *= 2
            val bitmap = resolver.openInputStream(uri)?.use {
                BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
            } ?: return null
            val longest = maxOf(bitmap.width, bitmap.height)
            val bounded = if (longest > maxPixel) {
                val scale = maxPixel.toFloat() / longest
                Bitmap.createScaledBitmap(
                    bitmap,
                    (bitmap.width * scale).toInt().coerceAtLeast(1),
                    (bitmap.height * scale).toInt().coerceAtLeast(1),
                    true,
                )
            } else {
                bitmap
            }
            val out = ByteArrayOutputStream()
            bounded.compress(Bitmap.CompressFormat.JPEG, 80, out)
            if (bounded !== bitmap) bounded.recycle()
            bitmap.recycle()
            out.toByteArray()
        } catch (error: Exception) {
            Log.w(TAG, "MMS part $partId could not be drawn", error)
            null
        }
    }

    // region Conversations

    /** The provider's own list. Some vendors break it, hence the fallback. */
    private fun conversations(): List<SmsThread> {
        val addresses = canonicalAddresses()
        val threads = mutableListOf<SmsThread>()
        resolver.query(
            Uri.parse("content://mms-sms/conversations?simple=true"),
            arrayOf("_id", "date", "message_count", "recipient_ids", "snippet"),
            null,
            null,
            "date DESC",
        )?.use { cursor ->
            while (cursor.moveToNext() && threads.size < SmsRules.MAX_THREADS) {
                val count = cursor.getInt(2)
                if (count == 0) continue
                val recipients = cursor.getStringOrNull(3).orEmpty()
                    .split(' ')
                    .mapNotNull { it.toLongOrNull()?.let(addresses::get) }
                threads += SmsThread(
                    id = cursor.getLong(0),
                    addresses = recipients,
                    snippet = SmsRules.snippet(cursor.getStringOrNull(4)),
                    date = cursor.getLong(1),
                    count = count,
                )
            }
        } ?: throw IllegalStateException("no conversation provider")
        return threads
    }

    private fun canonicalAddresses(): Map<Long, String> {
        val map = mutableMapOf<Long, String>()
        resolver.query(Uri.parse("content://mms-sms/canonical-addresses"), arrayOf("_id", "address"), null, null, null)
            ?.use { cursor ->
                while (cursor.moveToNext()) {
                    cursor.getStringOrNull(1)?.let { map[cursor.getLong(0)] = it }
                }
            }
        return map
    }

    /** The newest SMS of each conversation, when the provider's list is not there. */
    private fun conversationsFromTables(): List<SmsThread> {
        val latest = linkedMapOf<Long, SmsThread>()
        val counts = mutableMapOf<Long, Int>()
        resolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE),
            "${Telephony.Sms.TYPE} != 3",
            null,
            "${Telephony.Sms.DATE} DESC",
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val thread = cursor.getLong(0)
                counts[thread] = (counts[thread] ?: 0) + 1
                if (thread in latest || latest.size >= SmsRules.MAX_THREADS) continue
                latest[thread] = SmsThread(
                    id = thread,
                    addresses = listOfNotNull(cursor.getStringOrNull(1)),
                    snippet = SmsRules.snippet(cursor.getStringOrNull(2)),
                    date = cursor.getLong(3),
                    lastFromMe = cursor.getInt(4) != 1,
                )
            }
        }
        return latest.values.map { it.copy(count = counts[it.id]) }
    }

    private fun unreadCounts(): Map<Long, Int> {
        val counts = mutableMapOf<Long, Int>()
        fun count(uri: Uri, threadColumn: String) {
            resolver.query(uri, arrayOf(threadColumn), "read = 0", null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val thread = cursor.getLong(0)
                    counts[thread] = (counts[thread] ?: 0) + 1
                }
            }
        }
        count(Telephony.Sms.Inbox.CONTENT_URI, Telephony.Sms.THREAD_ID)
        runCatching { count(Telephony.Mms.Inbox.CONTENT_URI, Telephony.Mms.THREAD_ID) }
        return counts
    }

    // endregion

    // region Messages

    private fun smsMessages(threadId: Long, after: Long?, before: Long?, limit: Int): List<SmsMessage> {
        val selection = StringBuilder("${Telephony.Sms.THREAD_ID} = ? AND ${Telephony.Sms.TYPE} != 3")
        val args = mutableListOf(threadId.toString())
        after?.let { selection.append(" AND ${Telephony.Sms.DATE} > ?"); args += it.toString() }
        before?.let { selection.append(" AND ${Telephony.Sms.DATE} < ?"); args += it.toString() }
        val list = mutableListOf<SmsMessage>()
        resolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(
                Telephony.Sms._ID, Telephony.Sms.DATE, Telephony.Sms.TYPE, Telephony.Sms.BODY,
                Telephony.Sms.STATUS, Telephony.Sms.ADDRESS,
            ),
            selection.toString(),
            args.toTypedArray(),
            "${Telephony.Sms.DATE} DESC",
        )?.use { cursor ->
            while (cursor.moveToNext() && list.size < limit) {
                val type = cursor.getInt(2)
                list += SmsMessage(
                    id = "s${cursor.getLong(0)}",
                    date = cursor.getLong(1),
                    fromMe = type != 1,
                    text = cursor.getStringOrNull(3),
                    status = SmsRules.smsStatus(type, cursor.getInt(4)),
                    address = if (type == 1) cursor.getStringOrNull(5) else null,
                )
            }
        }
        return list
    }

    /** MMS dates are seconds, not milliseconds; the bounds are widened and cut again in code. */
    private fun mmsMessages(threadId: Long, after: Long?, before: Long?, limit: Int): List<SmsMessage> {
        val selection = StringBuilder("${Telephony.Mms.THREAD_ID} = ? AND ${Telephony.Mms.MESSAGE_BOX} != 3")
        val args = mutableListOf(threadId.toString())
        after?.let { selection.append(" AND ${Telephony.Mms.DATE} >= ?"); args += (it / 1000).toString() }
        before?.let { selection.append(" AND ${Telephony.Mms.DATE} <= ?"); args += (it / 1000 + 1).toString() }
        val rows = mutableListOf<Triple<Long, Long, Int>>()
        resolver.query(
            Telephony.Mms.CONTENT_URI,
            arrayOf(Telephony.Mms._ID, Telephony.Mms.DATE, Telephony.Mms.MESSAGE_BOX),
            selection.toString(),
            args.toTypedArray(),
            "${Telephony.Mms.DATE} DESC",
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val date = cursor.getLong(1) * 1000
                if (after != null && date <= after) continue
                if (before != null && date >= before) continue
                rows += Triple(cursor.getLong(0), date, cursor.getInt(2))
                if (rows.size >= limit) break
            }
        }
        return rows.map { (id, date, box) -> mmsMessage(id, date, box) }
    }

    private fun mmsMessage(id: Long, date: Long, box: Int): SmsMessage {
        val texts = mutableListOf<String>()
        val images = mutableListOf<SmsImage>()
        resolver.query(
            Uri.parse("content://mms/part"),
            arrayOf("_id", "ct", "text"),
            "mid = ?",
            arrayOf(id.toString()),
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val type = cursor.getStringOrNull(1).orEmpty()
                when {
                    type == "text/plain" -> cursor.getStringOrNull(2)?.let(texts::add)
                    type.startsWith("image/") -> images += imageOf(cursor.getLong(0), type)
                }
            }
        }
        return SmsMessage(
            id = "m$id",
            date = date,
            fromMe = box != 1,
            text = texts.joinToString("\n").ifEmpty { null },
            mms = true,
            images = images.ifEmpty { null },
            status = SmsRules.mmsStatus(box),
            address = if (box == 1) mmsSender(id) else null,
        )
    }

    /** The size is read from the header only, so the Mac can leave the right space. */
    private fun imageOf(partId: Long, mime: String): SmsImage {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        runCatching {
            resolver.openInputStream(Uri.parse("content://mms/part/$partId"))?.use {
                BitmapFactory.decodeStream(it, null, bounds)
            }
        }
        return SmsImage(
            partId = partId.toString(),
            mime = mime,
            width = bounds.outWidth.takeIf { it > 0 },
            height = bounds.outHeight.takeIf { it > 0 },
        )
    }

    private fun mmsSender(id: Long): String? = runCatching {
        resolver.query(Uri.parse("content://mms/$id/addr"), arrayOf("address"), "type = 137", null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) cursor.getStringOrNull(0) else null }
    }.getOrNull()

    private fun maxId(uri: Uri): Long =
        resolver.query(uri, arrayOf("_id"), null, null, "_id DESC")?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getLong(0) else 0L
        } ?: 0L

    // endregion

    // region Contacts

    /** What the phone's contacts say about one address. */
    private data class Contact(val name: String?, val photoId: Long?)

    private fun displayName(addresses: List<String>): String? {
        if (!Permissions.hasContacts(context) || addresses.isEmpty()) return null
        val found = addresses.map { contact(it)?.name }
        if (found.all { it == null }) return null
        return found.zip(addresses) { name, address -> name ?: address }.joinToString(", ")
    }

    /**
     * The id of the contact's photo, for a conversation with one person. It
     * changes when the photo does, which is how the Mac knows to ask again.
     */
    private fun photoOf(addresses: List<String>): String? =
        addresses.singleOrNull()?.let { contact(it)?.photoId }?.toString()

    private fun contact(address: String): Contact? {
        if (!Permissions.hasContacts(context)) return null
        return contacts.getOrPut(address) {
            runCatching {
                resolver.query(
                    Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(address)),
                    arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME, ContactsContract.PhoneLookup.PHOTO_ID),
                    null,
                    null,
                    null,
                )?.use { cursor ->
                    if (!cursor.moveToFirst()) return@use null
                    val photo = if (cursor.isNull(1)) null else cursor.getLong(1).takeIf { it > 0 }
                    Contact(cursor.getStringOrNull(0), photo)
                }
            }.getOrNull() ?: NO_CONTACT
        }.takeIf { it !== NO_CONTACT }
    }

    /**
     * The contact photo of [address] as a JPEG, no side longer than [maxPixel],
     * or null when the contact has none.
     */
    fun avatar(address: String, maxPixel: Int = SmsRules.AVATAR_PIXEL): ByteArray? {
        if (!Permissions.hasContacts(context)) return null
        return try {
            val contactUri = resolver.query(
                Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(address)),
                arrayOf(ContactsContract.PhoneLookup._ID, ContactsContract.PhoneLookup.LOOKUP_KEY),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) ContactsContract.Contacts.getLookupUri(cursor.getLong(0), cursor.getString(1)) else null
            } ?: return null
            val bitmap = ContactsContract.Contacts.openContactPhotoInputStream(resolver, contactUri, true)
                ?.use { BitmapFactory.decodeStream(it) }
                ?: return null
            val side = minOf(bitmap.width, bitmap.height)
            val square = Bitmap.createBitmap(bitmap, (bitmap.width - side) / 2, (bitmap.height - side) / 2, side, side)
            val scaled = if (side > maxPixel) Bitmap.createScaledBitmap(square, maxPixel, maxPixel, true) else square
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 85, out)
            listOf(scaled, square, bitmap).distinct().forEach { it.recycle() }
            out.toByteArray()
        } catch (error: Exception) {
            Log.w(TAG, "The contact photo could not be drawn", error)
            null
        }
    }

    /** A contact edited on the phone shows up the next time the Mac asks. */
    fun forgetNames() = contacts.clear()

    // endregion

    private fun Cursor.getStringOrNull(column: Int): String? =
        if (column >= 0 && !isNull(column)) getString(column) else null

    private companion object {
        private const val TAG = Prefs.TAG
        private val NO_CONTACT = Contact(null, null)
    }
}

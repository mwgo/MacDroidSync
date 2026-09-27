package pl.wojas.macdroidsync

import org.json.JSONArray
import org.json.JSONObject

/**
 * Messages, see PROTOCOL.md section 9: the data that travels, and the pure rules
 * that shape it. Everything that touches the content provider lives in
 * [SmsReader], so what is here can be tested on the JVM.
 */

/** One conversation as the phone's messaging database has it. */
data class SmsThread(
    val id: Long,
    val addresses: List<String>,
    /** The contact's name, when this phone may read contacts and knows one. */
    val name: String? = null,
    val snippet: String? = null,
    /** Last activity, milliseconds since 1970. */
    val date: Long,
    val unread: Int = 0,
    val lastFromMe: Boolean? = null,
    val count: Int? = null,
    /** The contact photo's id; the picture itself is asked for with sms-avatar. */
    val photo: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("addresses", JSONArray(addresses))
        name?.let { put("name", it) }
        snippet?.let { put("snippet", it) }
        put("date", date)
        put("unread", unread)
        lastFromMe?.let { put("lastFromMe", it) }
        count?.let { put("count", it) }
        photo?.let { put("photo", it) }
    }

    companion object {
        fun fromJson(json: JSONObject) = SmsThread(
            id = json.optLong("id"),
            addresses = json.optJSONArray("addresses")?.strings().orEmpty(),
            name = json.stringOrNull("name"),
            snippet = json.stringOrNull("snippet"),
            date = json.optLong("date"),
            unread = json.optInt("unread"),
            lastFromMe = if (json.has("lastFromMe")) json.optBoolean("lastFromMe") else null,
            count = if (json.has("count")) json.optInt("count") else null,
            photo = json.stringOrNull("photo"),
        )
    }
}

/** A picture inside an MMS. Its bytes are asked for separately, by [partId]. */
data class SmsImage(
    val partId: String,
    val mime: String? = null,
    val width: Int? = null,
    val height: Int? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("partId", partId)
        mime?.let { put("mime", it) }
        width?.let { put("width", it) }
        height?.let { put("height", it) }
    }

    companion object {
        fun fromJson(json: JSONObject) = SmsImage(
            partId = json.optString("partId"),
            mime = json.stringOrNull("mime"),
            width = if (json.has("width")) json.optInt("width") else null,
            height = if (json.has("height")) json.optInt("height") else null,
        )
    }
}

/**
 * One message. [id] carries a prefix, "s" for SMS and "m" for MMS, because the
 * two tables number their rows independently and the same number turns up in
 * both.
 */
data class SmsMessage(
    val id: String,
    val date: Long,
    val fromMe: Boolean,
    val text: String? = null,
    val mms: Boolean? = null,
    val images: List<SmsImage>? = null,
    /** "pending", "sent", "delivered" or "failed"; absent for received ones. */
    val status: String? = null,
    /** Who sent it, in a group conversation. */
    val address: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("date", date)
        put("fromMe", fromMe)
        text?.let { put("text", it) }
        mms?.let { put("mms", it) }
        images?.let { list -> put("images", JSONArray().apply { list.forEach { put(it.toJson()) } }) }
        status?.let { put("status", it) }
        address?.let { put("address", it) }
    }

    companion object {
        fun fromJson(json: JSONObject) = SmsMessage(
            id = json.optString("id"),
            date = json.optLong("date"),
            fromMe = json.optBoolean("fromMe"),
            text = json.stringOrNull("text"),
            mms = if (json.has("mms")) json.optBoolean("mms") else null,
            images = json.optJSONArray("images")?.let { array ->
                (0 until array.length()).map { SmsImage.fromJson(array.getJSONObject(it)) }
            },
            status = json.stringOrNull("status"),
            address = json.stringOrNull("address"),
        )
    }
}

/**
 * The `sms` field of a message. Which fields are set depends on the type; see
 * the table in PROTOCOL.md section 9. [state] is a plain string on purpose, a
 * value the other side does not know must not break decoding.
 */
data class SmsPayload(
    val requestId: String? = null,
    val threadId: Long? = null,
    val after: Long? = null,
    val before: Long? = null,
    val limit: Int? = null,
    val threads: List<SmsThread>? = null,
    val messages: List<SmsMessage>? = null,
    val more: Boolean? = null,
    val thread: SmsThread? = null,
    val address: String? = null,
    val text: String? = null,
    val state: String? = null,
    val partId: String? = null,
    /** On sms-avatar: the photo id the Mac is asking about, echoed back. */
    val photo: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        requestId?.let { put("requestId", it) }
        threadId?.let { put("threadId", it) }
        after?.let { put("after", it) }
        before?.let { put("before", it) }
        limit?.let { put("limit", it) }
        threads?.let { list -> put("threads", JSONArray().apply { list.forEach { put(it.toJson()) } }) }
        messages?.let { list -> put("messages", JSONArray().apply { list.forEach { put(it.toJson()) } }) }
        more?.let { put("more", it) }
        thread?.let { put("thread", it.toJson()) }
        address?.let { put("address", it) }
        text?.let { put("text", it) }
        state?.let { put("state", it) }
        partId?.let { put("partId", it) }
        photo?.let { put("photo", it) }
    }

    companion object {
        fun fromJson(json: JSONObject) = SmsPayload(
            requestId = json.stringOrNull("requestId"),
            threadId = if (json.has("threadId")) json.optLong("threadId") else null,
            after = if (json.has("after")) json.optLong("after") else null,
            before = if (json.has("before")) json.optLong("before") else null,
            limit = if (json.has("limit")) json.optInt("limit") else null,
            threads = json.optJSONArray("threads")?.let { array ->
                (0 until array.length()).map { SmsThread.fromJson(array.getJSONObject(it)) }
            },
            messages = json.optJSONArray("messages")?.let { array ->
                (0 until array.length()).map { SmsMessage.fromJson(array.getJSONObject(it)) }
            },
            more = if (json.has("more")) json.optBoolean("more") else null,
            thread = json.optJSONObject("thread")?.let { SmsThread.fromJson(it) },
            address = json.stringOrNull("address"),
            text = json.stringOrNull("text"),
            state = json.stringOrNull("state"),
            partId = json.stringOrNull("partId"),
            photo = json.stringOrNull("photo"),
        )
    }
}

/** The rules that do not need a content provider. */
object SmsRules {
    const val MAX_THREADS = 200
    const val DEFAULT_PAGE = 100
    const val MAX_PAGE = 200
    const val MAX_SNIPPET = 160
    /** How far back unread messages are announced when a session starts. */
    const val UNREAD_WINDOW_MS = 7L * 24 * 60 * 60 * 1000
    const val MAX_UNREAD = 50

    /** Longest side of an MMS picture sent to the Mac. */
    const val MAX_IMAGE_PIXEL = 1280
    /** Side of a contact photo sent to the Mac, square. */
    const val AVATAR_PIXEL = 192

    /**
     * Newest [limit] of both tables, oldest first, and whether older ones were
     * left out. The two lists each come back newest first and already limited,
     * so their union holds everything that can make the cut.
     */
    fun page(sms: List<SmsMessage>, mms: List<SmsMessage>, limit: Int): Pair<List<SmsMessage>, Boolean> {
        val all = (sms + mms).sortedWith(compareByDescending<SmsMessage> { it.date }.thenByDescending { it.id })
        return all.take(limit).reversed() to (all.size > limit)
    }

    fun clampLimit(asked: Int?): Int = (asked ?: DEFAULT_PAGE).coerceIn(1, MAX_PAGE)

    fun snippet(text: String?): String? {
        val flat = text?.replace(Regex("\\s+"), " ")?.trim()
        if (flat.isNullOrEmpty()) return null
        return if (flat.length <= MAX_SNIPPET) flat else flat.take(MAX_SNIPPET - 1) + "…"
    }

    /**
     * Telephony.Sms TYPE and STATUS as one word. Drafts (type 3) never get here,
     * the reader leaves them out.
     */
    fun smsStatus(type: Int, status: Int): String? = when (type) {
        1 -> null
        5 -> "failed"
        4, 6 -> "pending"
        else -> when (status) {
            0 -> "delivered"
            64 -> "failed"
            else -> "sent"
        }
    }

    /** Telephony.Mms MESSAGE_BOX in the same words. */
    fun mmsStatus(box: Int): String? = when (box) {
        1 -> null
        4 -> "pending"
        5 -> "failed"
        else -> "sent"
    }

    /** Whether a reply can go to [address]: a sender name like "BANK" cannot take one. */
    fun canReply(address: String): Boolean = address.count { it.isDigit() } >= 3
}

private fun JSONObject.stringOrNull(key: String): String? =
    if (has(key) && !isNull(key)) optString(key) else null

private fun JSONArray.strings(): List<String> = (0 until length()).map { optString(it) }

package pl.wojas.macdroidsync

import org.json.JSONObject

/** Wire constants shared with the macOS app, see PROTOCOL.md. */
object Wire {
    const val VERSION = 1
    const val DEFAULT_PORT = 47831
    const val SERVICE_TYPE = "_macdroidsync._tcp"

    const val MAX_FRAME_SIZE = 4 * 1024 * 1024
    const val MAX_CLIPBOARD_BYTES = 512 * 1024

    /** Raw bytes per file-chunk; base64 grows it by a third. */
    const val FILE_CHUNK_BYTES = 192 * 1024
    /** The Mac refuses anything bigger, so there is no point in starting. */
    const val MAX_FILE_BYTES = 512L * 1024 * 1024

    const val HEARTBEAT_INTERVAL_MS = 15_000L
    const val RECEIVE_TIMEOUT_MS = 30_000L

    const val KIND_PLAINTEXT: Byte = 0x01
    const val KIND_ENCRYPTED: Byte = 0x02
}

object MessageType {
    const val CHALLENGE = "challenge"
    const val HELLO = "hello"
    const val HELLO_ACK = "hello-ack"
    const val CLIPBOARD = "clipboard"
    const val CLIPBOARD_ACK = "clipboard-ack"
    const val REQUEST_CLIPBOARD = "request-clipboard"
    const val PING = "ping"
    const val PONG = "pong"
    const val HEARTBEAT = "heartbeat"
    const val BYE = "bye"
    const val FILE_OFFER = "file-offer"
    const val FILE_CHUNK = "file-chunk"
    const val FILE_END = "file-end"
    const val FILE_ACK = "file-ack"
}

/** One protocol message; absent fields are left out of the JSON payload. */
data class Message(
    val type: String,
    val seq: Long = 0,
    val v: Int = Wire.VERSION,
    val ts: Long = System.currentTimeMillis(),
    val text: String? = null,
    val device: String? = null,
    val deviceId: String? = null,
    val challenge: String? = null,
    val token: Long? = null,
    val reason: String? = null,
    // File transfer, see PROTOCOL.md section 6.
    val fileId: String? = null,
    val name: String? = null,
    val size: Long? = null,
    val mime: String? = null,
    val sha256: String? = null,
    /** Base64 of one file-chunk payload. */
    val data: String? = null,
    val ok: Boolean? = null,
    val path: String? = null,
) {
    fun toBytes(): ByteArray {
        val json = JSONObject()
        json.put("v", v)
        json.put("seq", seq)
        json.put("type", type)
        json.put("ts", ts)
        text?.let { json.put("text", it) }
        device?.let { json.put("device", it) }
        deviceId?.let { json.put("deviceId", it) }
        challenge?.let { json.put("challenge", it) }
        token?.let { json.put("token", it) }
        reason?.let { json.put("reason", it) }
        fileId?.let { json.put("fileId", it) }
        name?.let { json.put("name", it) }
        size?.let { json.put("size", it) }
        mime?.let { json.put("mime", it) }
        sha256?.let { json.put("sha256", it) }
        data?.let { json.put("data", it) }
        ok?.let { json.put("ok", it) }
        path?.let { json.put("path", it) }
        return json.toString().toByteArray(Charsets.UTF_8)
    }

    companion object {
        fun parse(bytes: ByteArray): Message {
            val json = JSONObject(String(bytes, Charsets.UTF_8))
            return Message(
                type = json.optString("type"),
                seq = json.optLong("seq"),
                v = json.optInt("v", Wire.VERSION),
                ts = json.optLong("ts"),
                text = json.optStringOrNull("text"),
                device = json.optStringOrNull("device"),
                deviceId = json.optStringOrNull("deviceId"),
                challenge = json.optStringOrNull("challenge"),
                token = if (json.has("token")) json.optLong("token") else null,
                reason = json.optStringOrNull("reason"),
                fileId = json.optStringOrNull("fileId"),
                name = json.optStringOrNull("name"),
                size = if (json.has("size")) json.optLong("size") else null,
                mime = json.optStringOrNull("mime"),
                sha256 = json.optStringOrNull("sha256"),
                data = json.optStringOrNull("data"),
                ok = if (json.has("ok")) json.optBoolean("ok") else null,
                path = json.optStringOrNull("path"),
            )
        }

        private fun JSONObject.optStringOrNull(key: String): String? =
            if (has(key) && !isNull(key)) optString(key) else null
    }
}

/** `[4 byte big endian length][1 byte kind][body]` framing. */
object Framing {
    fun frame(kind: Byte, body: ByteArray): ByteArray {
        val length = body.size + 1
        val out = ByteArray(4 + length)
        out[0] = (length ushr 24 and 0xFF).toByte()
        out[1] = (length ushr 16 and 0xFF).toByte()
        out[2] = (length ushr 8 and 0xFF).toByte()
        out[3] = (length and 0xFF).toByte()
        out[4] = kind
        body.copyInto(out, 5)
        return out
    }
}

class ProtocolException(message: String) : Exception(message)

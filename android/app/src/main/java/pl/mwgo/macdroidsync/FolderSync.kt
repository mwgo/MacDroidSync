package pl.mwgo.macdroidsync

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.text.Normalizer
import java.util.Locale

/** One file or folder of a synced folder, see PROTOCOL.md section 10. */
data class FolderEntry(
    /** The path relative to the folder, `/` between the parts. */
    val p: String,
    /** Size in bytes; 0 for a folder. */
    val s: Long = 0,
    /** Modified, milliseconds. */
    val m: Long = 0,
    /** Lowercase hex SHA-256 of a file; null for a folder. */
    val h: String? = null,
    val d: Boolean? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("p", p)
        put("s", s)
        put("m", m)
        h?.let { put("h", it) }
        d?.let { put("d", it) }
    }

    companion object {
        fun fromJson(json: JSONObject) = FolderEntry(
            p = json.optString("p"),
            s = json.optLong("s"),
            m = json.optLong("m"),
            h = json.text("h"),
            d = if (json.has("d")) json.optBoolean("d") else null,
        )
    }
}

/** A pair as the Mac describes it in folders-config, and as the phone answers. */
data class FolderPairConfig(
    val id: String,
    val path: String? = null,
    val ok: Boolean? = null,
    val reason: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        path?.let { put("path", it) }
        ok?.let { put("ok", it) }
        reason?.let { put("reason", it) }
    }

    companion object {
        fun fromJson(json: JSONObject) = FolderPairConfig(
            id = json.optString("id"),
            path = json.text("path"),
            ok = if (json.has("ok")) json.optBoolean("ok") else null,
            reason = json.text("reason"),
        )
    }
}

/**
 * The `folder` field of a message. Which fields are set depends on the type;
 * see the table in PROTOCOL.md section 10.
 */
data class FolderPayload(
    val requestId: String? = null,
    val pairs: List<FolderPairConfig>? = null,
    val pair: String? = null,
    val cursor: Int? = null,
    val entries: List<FolderEntry>? = null,
    val path: String? = null,
    val to: String? = null,
    val offset: Long? = null,
    val total: Long? = null,
    val sha256: String? = null,
    val baseHash: String? = null,
    val dir: Boolean? = null,
    val paths: List<String>? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        requestId?.let { put("requestId", it) }
        pairs?.let { list -> put("pairs", JSONArray().apply { list.forEach { put(it.toJson()) } }) }
        pair?.let { put("pair", it) }
        cursor?.let { put("cursor", it) }
        entries?.let { list -> put("entries", JSONArray().apply { list.forEach { put(it.toJson()) } }) }
        path?.let { put("path", it) }
        to?.let { put("to", it) }
        offset?.let { put("offset", it) }
        total?.let { put("total", it) }
        sha256?.let { put("sha256", it) }
        baseHash?.let { put("baseHash", it) }
        dir?.let { put("dir", it) }
        paths?.let { put("paths", JSONArray(it)) }
    }

    companion object {
        fun fromJson(json: JSONObject) = FolderPayload(
            requestId = json.text("requestId"),
            pairs = json.optJSONArray("pairs")?.let { a -> (0 until a.length()).map { FolderPairConfig.fromJson(a.getJSONObject(it)) } },
            pair = json.text("pair"),
            cursor = if (json.has("cursor")) json.optInt("cursor") else null,
            entries = json.optJSONArray("entries")?.let { a -> (0 until a.length()).map { FolderEntry.fromJson(a.getJSONObject(it)) } },
            path = json.text("path"),
            to = json.text("to"),
            offset = if (json.has("offset")) json.optLong("offset") else null,
            total = if (json.has("total")) json.optLong("total") else null,
            sha256 = json.text("sha256"),
            baseHash = json.text("baseHash"),
            dir = if (json.has("dir")) json.optBoolean("dir") else null,
            paths = json.optJSONArray("paths")?.let { a -> (0 until a.length()).map { a.optString(it) } },
        )
    }
}

private fun JSONObject.text(key: String): String? = if (has(key) && !isNull(key)) optString(key) else null

/** What travels and what does not, the same rules as on the Mac. */
object FolderRules {
    /** Larger files are left where they are. */
    const val MAX_FILE_SIZE = 512L * 1024 * 1024
    /** Raw bytes per folder-get or folder-put piece. */
    const val CHUNK = 1024 * 1024
    /** The phone's own corner of each synced folder: its trash and the pieces in progress. */
    const val OWN_DIRECTORY = ".macdroidsync"

    fun isExcluded(name: String): Boolean =
        name == ".DS_Store" ||
            name.startsWith("._") ||
            name == "Icon\r" ||
            name.startsWith(".Trash") ||
            name == OWN_DIRECTORY ||
            name.endsWith(".part") ||
            name.endsWith(".macdroidsync-part") ||
            name == ".localized"

    /** A relative path within the folder: no `..`, nothing excluded on the way. */
    fun isValid(path: String): Boolean {
        if (path.isEmpty() || path.startsWith("/") || path.contains('\\') || path.contains('\u0000')) return false
        return path.split('/').all { it.isNotEmpty() && it != "." && it != ".." && !isExcluded(it) }
    }

    /** Two paths name the same file when this is equal: the phone's storage ignores case. */
    fun key(path: String): String = Normalizer.normalize(path, Normalizer.Form.NFC).lowercase(Locale.ROOT)

    fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}

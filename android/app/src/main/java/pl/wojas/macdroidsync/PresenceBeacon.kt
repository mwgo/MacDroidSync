package pl.wojas.macdroidsync

import java.nio.ByteBuffer
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Identity of the Bluetooth LE presence beacon this phone broadcasts, byte
 * compatible with the Swift implementation. See PROTOCOL.md section 7.
 *
 * The service UUID is derived from the pairing code, so only the paired Mac
 * recognises the beacon, and the payload carries a truncated HMAC over the
 * current 30 second slot, so a recorded packet stops working within a minute.
 *
 * Everything travels in the primary advertisement, which caps the payload:
 *
 *     flags element                       3 bytes
 *     complete 128 bit service UUID      18 bytes
 *     manufacturer data 0xFFFF + payload  4 + 6 bytes
 *     ----------------------------------------------
 *                                        31 bytes, the legacy limit
 *
 * No Android APIs are used here on purpose, so the vectors can be asserted by a
 * plain JVM unit test. The radio lives in [PresenceAdvertiser].
 */
object PresenceBeacon {
    /** Bit 0: this phone agrees to the Mac locking itself. */
    const val FLAG_AUTO_LOCK: Byte = 0x01
    const val SLOT_SECONDS = 30L
    /** 0xFFFF is reserved for testing, so it needs no Bluetooth SIG assignment. */
    const val MANUFACTURER_ID = 0xFFFF
    /**
     * Bytes of the truncated HMAC. Forty bits are ample: a forgery buys nothing
     * but a Mac that fails to lock, and there is no feedback to guess against.
     */
    const val MAC_LENGTH = 5
    const val PAYLOAD_LENGTH = 1 + MAC_LENGTH

    private val UUID_INFO = "presence-beacon".toByteArray(Charsets.UTF_8)
    private val TOKEN_INFO = "presence-token".toByteArray(Charsets.UTF_8)
    /** Domain separator, so this HMAC cannot be confused with any other. */
    private val DOMAIN = "MDS1".toByteArray(Charsets.UTF_8)

    fun serviceUuidBytes(pairingCode: String): ByteArray =
        CryptoBox.deriveKey(pairingCode, UUID_INFO, 16)

    /**
     * The derived UUID, used verbatim: the 16 bytes are not massaged into an
     * RFC 4122 version, because both sides only ever compare them.
     */
    fun serviceUuid(pairingCode: String): UUID {
        val buffer = ByteBuffer.wrap(serviceUuidBytes(pairingCode))
        return UUID(buffer.long, buffer.long)
    }

    fun slot(epochMillis: Long = System.currentTimeMillis()): Long =
        epochMillis / 1000 / SLOT_SECONDS

    /** The manufacturer specific payload for one slot: `[flags][mac]`. */
    fun payload(pairingCode: String, flags: Byte, slot: Long): ByteArray =
        byteArrayOf(flags) + mac(pairingCode, flags, slot)

    /** The payload for whatever slot is current right now. */
    fun currentPayload(
        pairingCode: String,
        flags: Byte = FLAG_AUTO_LOCK,
        epochMillis: Long = System.currentTimeMillis(),
    ): ByteArray = payload(pairingCode, flags, slot(epochMillis))

    private fun mac(pairingCode: String, flags: Byte, slot: Long): ByteArray {
        val key = CryptoBox.deriveKey(pairingCode, TOKEN_INFO, 32)
        val message = ByteBuffer.allocate(DOMAIN.size + 8 + 1)
            .put(DOMAIN)
            .putLong(slot)
            .put(flags)
            .array()
        val hmac = Mac.getInstance("HmacSHA256")
        hmac.init(SecretKeySpec(key, "HmacSHA256"))
        return hmac.doFinal(message).copyOfRange(0, MAC_LENGTH)
    }
}

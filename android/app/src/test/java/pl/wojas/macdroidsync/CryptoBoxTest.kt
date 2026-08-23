package pl.wojas.macdroidsync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * The vectors below are documented in PROTOCOL.md and asserted by the Swift test
 * suite as well, so both implementations stay byte compatible.
 */
class CryptoBoxTest {
    private val pairingCode = "ABCD-EFGH-JKLM-NPQR"
    private val expectedKey = "8fbe4a33389056e7d5beebae8fa395bbb3f550ba601a2fa58742825b6729349e"
    private val nonceHex = "0a0b0c0d0000000000000001"
    private val plaintext = """{"seq":1,"ts":1700000000000,"type":"ping","v":1}"""
    private val expectedSealed =
        "0a0b0c0d000000000000000153ee74cf645d5e54bcd32aa4545e08dd3481b931abaaf961" +
            "0008bdd6e02f3ac813e9ab23b25e59c926edff17cc448bc02664ab0c4cacf5f707397bd2" +
            "ac6c1e3c"

    @Test
    fun normalizationIgnoresCaseAndSeparators() {
        assertEquals("ABCDEFGHJKLMNPQR", CryptoBox.normalize("abcd efgh-jklm_npqr"))
    }

    @Test
    fun derivedKeyMatchesVector() {
        assertEquals(expectedKey, CryptoBox.deriveKey(pairingCode).hex())
        assertEquals(expectedKey, CryptoBox.deriveKey("abcdefghjklmnpqr").hex())
    }

    @Test
    fun sealMatchesVector() {
        val sealed = CryptoBox.seal(
            plaintext.toByteArray(Charsets.UTF_8),
            CryptoBox.deriveKey(pairingCode),
            nonceHex.unhex(),
        )
        assertEquals(expectedSealed, sealed.hex())
    }

    @Test
    fun openVector() {
        val opened = CryptoBox.open(expectedSealed.unhex(), CryptoBox.deriveKey(pairingCode))
        assertEquals(plaintext, String(opened, Charsets.UTF_8))

        val message = Message.parse(opened)
        assertEquals(MessageType.PING, message.type)
        assertEquals(1L, message.seq)
        assertEquals(1_700_000_000_000L, message.ts)
    }

    @Test
    fun wrongPairingCodeFailsAuthentication() {
        assertThrows(ProtocolException::class.java) {
            CryptoBox.open(expectedSealed.unhex(), CryptoBox.deriveKey("ZZZZ-ZZZZ-ZZZZ-ZZZZ"))
        }
    }

    @Test
    fun frameMatchesVector() {
        val frame = Framing.frame(Wire.KIND_ENCRYPTED, expectedSealed.unhex())
        assertEquals(81, frame.size)
        assertEquals("0000004d02", frame.copyOfRange(0, 5).hex())
    }

    @Test
    fun codecRoundTripUsesFreshNonces() {
        val sender = FrameCodec(pairingCode)
        val receiver = FrameCodec(pairingCode)

        val bodies = (1..3).map { sender.seal(Message(type = MessageType.HEARTBEAT, seq = sender.nextSequence())) }
        val nonces = bodies.map { it.copyOfRange(0, 12).hex() }
        assertEquals(3, nonces.toSet().size)
        assertEquals(1, nonces.map { it.substring(0, 8) }.toSet().size)

        bodies.forEachIndexed { index, body ->
            assertEquals((index + 1).toLong(), receiver.open(body).seq)
        }
    }

    @Test
    fun replayIsRejected() {
        val sender = FrameCodec(pairingCode)
        val receiver = FrameCodec(pairingCode)
        val body = sender.seal(Message(type = MessageType.PING, seq = sender.nextSequence()))

        assertEquals(MessageType.PING, receiver.open(body).type)
        assertThrows(ProtocolException::class.java) { receiver.open(body) }
    }

    @Test
    fun messageJsonRoundTrip() {
        // Deliberately non-ASCII: clipboard payloads must survive the UTF-8 round trip.
        val original = Message(
            type = MessageType.CLIPBOARD,
            seq = 7,
            ts = 1_700_000_000_123,
            text = "na\u00EFve caf\u00E9 \u65E5\u672C\u8A9E \u2713",
            token = 424242,
        )
        val parsed = Message.parse(original.toBytes())
        assertEquals(original.text, parsed.text)
        assertEquals(original.seq, parsed.seq)
        assertEquals(original.token, parsed.token)
        assertEquals(original.ts, parsed.ts)
        assertNotEquals(null, parsed.type)
    }

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

    private fun String.unhex(): ByteArray {
        val cleaned = filter { !it.isWhitespace() }
        return ByteArray(cleaned.length / 2) {
            cleaned.substring(it * 2, it * 2 + 2).toInt(16).toByte()
        }
    }
}

package pl.wojas.macdroidsync

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * The presence beacon has to be byte identical to the Swift side, otherwise the
 * Mac silently ignores every packet this phone sends. These are the same vectors
 * PresenceBeaconTests asserts, see PROTOCOL.md section 6.
 */
class PresenceBeaconTest {

    private val code = "ABCD-EFGH-JKLM-NPQR"

    /** 1700000000 / 30, the same instant the channel vectors use. */
    private val slot = 56_666_666L

    @Test
    fun `service uuid matches the cross platform vector`() {
        assertEquals("993bbecdd85ea9a50f0f705378a22fac", PresenceBeacon.serviceUuidBytes(code).hex())
        assertEquals("993bbecd-d85e-a9a5-0f0f-705378a22fac", PresenceBeacon.serviceUuid(code).toString())
    }

    @Test
    fun `payload matches the cross platform vector`() {
        val payload = PresenceBeacon.payload(code, PresenceBeacon.FLAG_AUTO_LOCK, slot)
        assertEquals(PresenceBeacon.PAYLOAD_LENGTH, payload.size)
        assertEquals("01ae64c93d94", payload.hex())
    }

    @Test
    fun `the uuid is unrelated to the channel key`() {
        // Same pairing code, different HKDF info: the beacon is broadcast in the
        // clear, so it must give nothing away about the clipboard key.
        val channelKey = CryptoBox.deriveKey(code).copyOfRange(0, 16)
        assertNotEquals(channelKey.hex(), PresenceBeacon.serviceUuidBytes(code).hex())
    }

    @Test
    fun `a different pairing code is a different beacon`() {
        assertNotEquals(
            PresenceBeacon.serviceUuidBytes(code).hex(),
            PresenceBeacon.serviceUuidBytes("ABCD-EFGH-JKLM-NPQS").hex(),
        )
    }

    @Test
    fun `the pairing code is normalised like everywhere else`() {
        assertArrayEquals(
            PresenceBeacon.serviceUuidBytes(code),
            PresenceBeacon.serviceUuidBytes("abcdefgh jklm-npqr"),
        )
    }

    @Test
    fun `every slot gets its own token`() {
        val tokens = (-2L..2L).map { PresenceBeacon.payload(code, PresenceBeacon.FLAG_AUTO_LOCK, slot + it).hex() }
        assertEquals(tokens.size, tokens.toSet().size)
        // The neighbours the Mac still accepts, pinned down here as well.
        assertEquals("01a9b137d4a0", tokens[1])
        assertEquals("019354cefcd3", tokens[3])
    }

    @Test
    fun `the flags are covered by the token`() {
        assertNotEquals(
            PresenceBeacon.payload(code, PresenceBeacon.FLAG_AUTO_LOCK, slot).hex(),
            PresenceBeacon.payload(code, 0, slot).hex(),
        )
    }

    @Test
    fun `slot boundaries fall on multiples of thirty seconds`() {
        assertEquals(slot, PresenceBeacon.slot(1_699_999_980_000))
        assertEquals(slot, PresenceBeacon.slot(1_700_000_000_000))
        assertEquals(slot, PresenceBeacon.slot(1_700_000_009_999))
        assertEquals(slot + 1, PresenceBeacon.slot(1_700_000_010_000))
    }

    @Test
    fun `the whole advertisement fits in thirty one bytes`() {
        // 3 flags + 18 service UUID + 2 header + 2 company id + payload.
        val advertisement = 3 + 18 + 2 + 2 + PresenceBeacon.PAYLOAD_LENGTH
        assertEquals(true, advertisement <= 31)
    }

    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }
}

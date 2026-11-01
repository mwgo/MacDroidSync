package pl.mwgo.macdroidsync

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class FujiPtpTest {

    @Test
    fun `init packet carries fuji's version, guid and the name`() {
        val packet = FujiPtp.initPacket("Pixel")
        assertEquals(82, packet.size)
        assertArrayEquals(
            byteArrayOf(0x52, 0, 0, 0, 1, 0, 0, 0, 0xF2.toByte(), 0xE4.toByte(), 0x53, 0x8F.toByte()),
            packet.copyOfRange(0, 12),
        )
        assertArrayEquals(
            byteArrayOf(0xAD.toByte(), 0xA5.toByte(), 0x48, 0x5D, 0x87.toByte(), 0xB2.toByte(), 0x7F, 0x0B),
            packet.copyOfRange(12, 20),
        )
        assertEquals("Pixel", String(packet.copyOfRange(28, 38), Charsets.UTF_16LE))
        assertEquals(0, packet[38].toInt())
    }

    @Test
    fun `command is a usb style container`() {
        val bytes = FujiPtp.command(1, 0x1015, 7, intArrayOf(0xD212))
        assertArrayEquals(byteArrayOf(16, 0, 0, 0, 1, 0, 0x15, 0x10, 7, 0, 0, 0, 0x12, 0xD2.toByte(), 0, 0), bytes)
    }

    @Test
    fun `events are a count and code value pairs`() {
        val data = le(2 + 12).putShort(2).putShort(0xDF00.toShort()).putInt(6).putShort(0xD222.toShort()).putInt(0x9E).array()
        assertEquals(mapOf(0xDF00 to 6, 0xD222 to 0x9E), FujiPtp.parseEvents(data))
    }

    @Test
    fun `handles are a ptp array`() {
        assertEquals(listOf(1, 2, 5), FujiPtp.parseHandles(le(16).putInt(3).putInt(1).putInt(2).putInt(5).array()))
        assertEquals(emptyList<Int>(), FujiPtp.parseHandles(ByteArray(0)))
    }

    @Test
    fun `object info yields name, date and size`() {
        val buffer = le(200)
            .putInt(0x10000001).putShort(0x3801).putShort(0).putInt(12_345_678)
            .putShort(0x3801).putInt(9000).putInt(160).putInt(120)
            .putInt(7728).putInt(5152).putInt(24).putInt(0).putShort(0).putInt(0).putInt(0)
        string(buffer, "DSCF0042.JPG")
        string(buffer, "20261101T105400")
        val info = FujiPtp.parseObjectInfo(42, buffer.array())
        assertEquals("DSCF0042.JPG", info.filename)
        assertEquals("20261101T105400", info.captureDate)
        assertEquals(12_345_678L, info.size)
        assertEquals(7728, info.width)
        assertEquals(true, info.isJpeg)
    }

    @Test
    fun `the thumbnail is cut out of the exif head`() {
        val thumb = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1, 2, 3, 0xFF.toByte(), 0xD9.toByte())
        val head = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE1.toByte(), 9, 9) + thumb + byteArrayOf(7, 7)
        assertArrayEquals(thumb, FujiPtp.embeddedJpeg(head))
        assertEquals(null, FujiPtp.embeddedJpeg(byteArrayOf(1, 2, 3)))
    }

    private fun string(buffer: ByteBuffer, text: String) {
        buffer.put((text.length + 1).toByte())
        text.forEach { buffer.putChar(it) }
        buffer.putShort(0)
    }

    private fun le(size: Int) = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
}

package pl.wojas.macdroidsync

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

/** The parts of the MMS encoding that are easy to get wrong by one bit. */
class MmsPduTest {

    private fun uintvar(value: Long) = ByteArrayOutputStream().also { MmsPdu.uintvar(it, value) }.toByteArray()

    @Test
    fun `uintvar groups seven bits with a continuation flag`() {
        assertArrayEquals(byteArrayOf(0x00), uintvar(0))
        assertArrayEquals(byteArrayOf(0x7F), uintvar(127))
        assertArrayEquals(byteArrayOf(0x81.toByte(), 0x00), uintvar(128))
        assertArrayEquals(byteArrayOf(0x83.toByte(), 0xFF.toByte(), 0x7F), uintvar(65535))
    }

    @Test
    fun `a long value length is announced with 31`() {
        val short = ByteArrayOutputStream().also { MmsPdu.valueLength(it, 30) }.toByteArray()
        val long = ByteArrayOutputStream().also { MmsPdu.valueLength(it, 200) }.toByteArray()
        assertArrayEquals(byteArrayOf(30), short)
        assertArrayEquals(byteArrayOf(31, 0x81.toByte(), 0x48), long)
    }

    @Test
    fun `numbers are addressed to the mobile network`() {
        assertEquals("+48600100200/TYPE=PLMN", MmsPdu.address("+48 600 100 200"))
    }

    @Test
    fun `the request starts with its type and carries every part`() {
        val image = ByteArray(1000) { 1 }
        val pdu = MmsPdu.sendRequest("+48600100200", "hi", image)
        assertEquals(0x8C, pdu[0].toInt() and 0xFF)
        assertEquals(0x80, pdu[1].toInt() and 0xFF)
        val text = String(pdu, Charsets.ISO_8859_1)
        assertTrue(text.contains("+48600100200/TYPE=PLMN"))
        assertTrue(text.contains("<smil>"))
        assertTrue(text.contains("image.jpg"))
        assertTrue(text.endsWith("hi"))
        assertTrue(pdu.size > image.size)
    }
}

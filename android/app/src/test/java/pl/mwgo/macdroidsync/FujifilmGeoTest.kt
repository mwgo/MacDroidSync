package pl.mwgo.macdroidsync

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.TimeZone

class FujifilmGeoTest {

    // 2026-07-15 10:20:30 UTC
    private val summer = 1_784_110_830_000L

    @Test
    fun `location is packed as xapp does`() {
        val bytes = FujifilmGeo.location(50.0614300, 19.9365800, 219.6, 1.234f, summer)
        assertEquals(23, bytes.size)
        assertArrayEquals(le(500_614_300) + le(199_365_800) + le(220) + le(123), bytes.copyOfRange(0, 16))
        assertArrayEquals(byteArrayOf(0xEA.toByte(), 0x07, 7, 15, 10, 20, 30), bytes.copyOfRange(16, 23))
    }

    @Test
    fun `southern and western coordinates stay negative`() {
        val bytes = FujifilmGeo.location(-33.8688, -151.2093, -5.0, 0f, summer)
        assertArrayEquals(le(-338_688_000) + le(-1_512_093_000) + le(-5) + le(0), bytes.copyOfRange(0, 16))
    }

    @Test
    fun `time carries utc, the standard offset and summer time`() {
        val bytes = FujifilmGeo.utcAndTimezone(summer, TimeZone.getTimeZone("Europe/Warsaw"))
        assertArrayEquals(
            byteArrayOf(0xEA.toByte(), 0x07, 7, 15, 10, 20, 30) + le(100) + byteArrayOf(1),
            bytes,
        )
    }

    @Test
    fun `offsets keep quarter hours`() {
        assertEquals(550, FujifilmGeo.offset(5 * 3600 + 30 * 60))
        assertEquals(-350, FujifilmGeo.offset(-(3 * 3600 + 30 * 60)))
        assertEquals(575, FujifilmGeo.offset(5 * 3600 + 45 * 60))
        assertEquals(0, FujifilmGeo.offset(0))
    }

    @Test
    fun `local date and time for older cameras`() {
        val bytes = FujifilmGeo.dateTime(summer, TimeZone.getTimeZone("Europe/Warsaw"))
        assertArrayEquals(byteArrayOf(0xEA.toByte(), 0x07, 7, 15, 12, 20, 30), bytes)
    }

    @Test
    fun `interval is two bytes`() {
        assertArrayEquals(byteArrayOf(120, 0), FujifilmGeo.interval(120))
        assertArrayEquals(byteArrayOf(0xE0.toByte(), 1), FujifilmGeo.interval(480))
    }

    @Test
    fun `identification keeps the number and sets the xapp bit`() {
        assertArrayEquals(le(0x2000_1234), FujifilmGeo.identification(le(0x1234)))
        assertArrayEquals(le(0x2000_1234), FujifilmGeo.identification(le(0x2000_1234)))
        assertEquals(null, FujifilmGeo.identification(byteArrayOf(1, 2)))
    }

    @Test
    fun `device name ends with a zero`() {
        assertArrayEquals(byteArrayOf(0x50, 0x69, 0), FujifilmGeo.deviceName("Pi"))
    }

    private fun le(value: Int) = byteArrayOf(
        value.toByte(), (value shr 8).toByte(), (value shr 16).toByte(), (value shr 24).toByte(),
    )
}

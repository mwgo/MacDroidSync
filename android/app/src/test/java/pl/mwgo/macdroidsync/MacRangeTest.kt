package pl.mwgo.macdroidsync

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MacRangeTest {

    private val now = 1_700_000_000_000L

    @Test
    fun `a mac unseen for longer than the grace lets the service sleep`() {
        assertTrue(MacRange.shouldSleep(now, now - MacRange.AWAY_MS - 1, inRange = false, usable = true))
    }

    @Test
    fun `a mac seen a moment ago keeps it running`() {
        assertFalse(MacRange.shouldSleep(now, now - 10_000, inRange = false, usable = true))
    }

    @Test
    fun `a mac the controller still has in range keeps it running, however long ago it was found`() {
        assertFalse(MacRange.shouldSleep(now, now - MacRange.AWAY_MS * 10, inRange = true, usable = true))
    }

    @Test
    fun `a mac never seen may not advertise, so nothing would wake the phone`() {
        assertFalse(MacRange.shouldSleep(now, 0, inRange = false, usable = true))
    }

    @Test
    fun `without the scan there is no telling, so it keeps running`() {
        assertFalse(MacRange.shouldSleep(now, now - MacRange.AWAY_MS * 10, inRange = false, usable = false))
    }
}

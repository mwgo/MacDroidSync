package pl.mwgo.macdroidsync

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FujifilmNamesTest {

    @Test
    fun `fujifilm bodies are recognised by name`() {
        listOf("X-E5", "X-T50", "X-S20", "X-H2S", "X-Pro3", "X-M5", "X100VI", "GFX100S II", "x-t5_1234")
            .forEach { assertTrue(it, FujifilmNames.looksLikeCamera(it)) }
    }

    @Test
    fun `other devices are not`() {
        listOf(null, "", "Ford Focus", "Beoplay EX (Marcin)", "Xbox Wireless Controller", "EDIFIER STAX SPIRIT S5")
            .forEach { assertFalse(it.toString(), FujifilmNames.looksLikeCamera(it)) }
    }
}

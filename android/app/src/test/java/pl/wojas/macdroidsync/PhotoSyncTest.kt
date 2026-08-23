package pl.wojas.macdroidsync

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The question this file answers: does the phone describe its camera folder in a
 * way the Mac can act on without losing or duplicating photos? The wire keys are
 * asserted literally, because Swift and Kotlin have to agree byte for byte - the
 * same discipline as CryptoBoxTest and its vectors in PROTOCOL.md.
 */
class PhotoItemJsonTest {

    @Test
    fun `item uses the single letter keys`() {
        val json = PhotoItem(
            key = "DCIM/Camera/a.jpg",
            captureAt = 123,
            size = 456,
            mime = "image/jpeg",
            sha256 = "abc",
            excluded = PhotoExclusion.SIZE,
        ).toJson()

        assertEquals("DCIM/Camera/a.jpg", json.getString("k"))
        assertEquals(123L, json.getLong("t"))
        assertEquals(456L, json.getLong("s"))
        assertEquals("image/jpeg", json.getString("m"))
        assertEquals("abc", json.getString("h"))
        assertEquals("size", json.getString("x"))
    }

    @Test
    fun `absent fields stay out of the json`() {
        val json = PhotoItem(key = "k", captureAt = 1, size = 2).toJson()
        assertTrue(json.has("k"))
        assertTrue(!json.has("h"))
        assertTrue(!json.has("m"))
        assertTrue(!json.has("x"))
    }

    @Test
    fun `item survives a round trip`() {
        val item = PhotoItem("k", 7, 8, "video/mp4", "ff", PhotoExclusion.NO_LOCATION)
        assertEquals(item, PhotoItem.fromJson(item.toJson()))
    }

    @Test
    fun `payload carries only what was set`() {
        val payload = PhotoPayload(manifestId = "m1", page = 1, pages = 2, count = 700, from = 99)
        val json = payload.toJson()
        assertEquals("m1", json.getString("manifestId"))
        assertEquals(700, json.getInt("count"))
        assertEquals(99L, json.getLong("from"))
        assertTrue(!json.has("items"))
        assertTrue(!json.has("gone"))
        assertTrue(!json.has("keys"))
    }

    @Test
    fun `payload survives a round trip with items and tombstones`() {
        val payload = PhotoPayload(
            manifestId = "m1",
            page = 1,
            pages = 1,
            count = 2,
            from = 500,
            items = listOf(PhotoItem("a", 1, 2, sha256 = "aa"), PhotoItem("b", 3, 4)),
            gone = listOf("x", "y"),
            skipped = 3,
        )
        assertEquals(payload, PhotoPayload.fromJson(payload.toJson()))
    }

    @Test
    fun `a pull without keys means build a manifest now`() {
        val decoded = PhotoPayload.fromJson(JSONObject())
        assertNull(decoded.keys)
    }

    @Test
    fun `the photo payload rides inside a message`() {
        val message = Message(
            type = MessageType.PHOTO_MANIFEST,
            seq = 4,
            photo = PhotoPayload(manifestId = "m1", page = 1, pages = 1, count = 1, from = 5,
                items = listOf(PhotoItem("k", 6, 7))),
        )
        val parsed = Message.parse(message.toBytes())
        assertEquals("photo-manifest", parsed.type)
        assertEquals("m1", parsed.photo?.manifestId)
        assertEquals(listOf("k"), parsed.photo?.items?.map { it.key })
    }

    @Test
    fun `a message without a photo field parses as before`() {
        val parsed = Message.parse(Message(type = MessageType.PING, seq = 1).toBytes())
        assertNull(parsed.photo)
    }
}

/** The key has to survive a restore, and must never address something outside the folder. */
class PhotoKeyTest {

    @Test
    fun `the ordinary case is the path and the name`() {
        assertEquals("DCIM/Camera/a.jpg", PhotoKey.of("DCIM/Camera/", "a.jpg"))
    }

    @Test
    fun `a missing trailing slash is repaired`() {
        assertEquals("DCIM/Camera/a.jpg", PhotoKey.of("DCIM/Camera", "a.jpg"))
    }

    @Test
    fun `duplicate slashes and a leading dot are normalised away`() {
        assertEquals("DCIM/Camera/a.jpg", PhotoKey.of(".//DCIM//Camera//", "a.jpg"))
        assertEquals("DCIM/Camera/a.jpg", PhotoKey.of("/DCIM/Camera/", "a.jpg"))
    }

    @Test
    fun `a name that is really a path is refused`() {
        assertNull(PhotoKey.of("DCIM/Camera/", "sub/a.jpg"))
    }

    @Test
    fun `climbing out of the folder is refused`() {
        assertNull(PhotoKey.of("DCIM/../../etc/", "a.jpg"))
    }

    @Test
    fun `an empty name is refused`() {
        assertNull(PhotoKey.of("DCIM/Camera/", ""))
        assertNull(PhotoKey.of("DCIM/Camera/", null))
        assertNull(PhotoKey.of("DCIM/Camera/", "."))
    }
}

/** Both settings are lower bounds; the day count is the fuse. */
class PhotoWindowTest {

    private val now = 1_800_000_000_000L
    private val day = 86_400_000L

    @Test
    fun `the later bound wins`() {
        assertEquals(now - 30 * day, PhotoWindow.effectiveFrom(1_000_000_000_000L, 30, now))
    }

    @Test
    fun `a recent start date beats the day count`() {
        assertEquals(now - day, PhotoWindow.effectiveFrom(now - day, 30, now))
    }

    @Test
    fun `a zero day count is read as one day not as everything`() {
        assertEquals(now - day, PhotoWindow.effectiveFrom(0, 0, now))
    }

    @Test
    fun `an unknown capture date is in no window at all`() {
        assertTrue(!PhotoWindow.contains(0, 0))
        assertTrue(PhotoWindow.contains(now, now - day))
    }
}

/**
 * The date ladder. The case that matters most on this phone: files whose
 * modification time was refreshed by being copied around, while the name still
 * carries the truth. Using the modification time would drag the whole library
 * into every window.
 */
class PhotoCaptureDateTest {

    private val utc = 0

    @Test
    fun `date taken is used when MediaStore has it`() {
        assertEquals(1_767_530_469_000L, PhotoCaptureDate.resolve(1_767_530_469_000L, "x.jpg", utc))
    }

    @Test
    fun `a samsung name resolves to its own date`() {
        // 2026-01-19 18:41:46 UTC
        assertEquals(1_768_848_106_000L, PhotoCaptureDate.resolve(null, "20260119_184146.jpg", utc))
    }

    @Test
    fun `prefixed names resolve too`() {
        val expected = 1_768_848_106_000L
        assertEquals(expected, PhotoCaptureDate.resolve(null, "IMG_20260119_184146.jpg", utc))
        assertEquals(expected, PhotoCaptureDate.resolve(null, "VID_20260119_184146.mp4", utc))
        assertEquals(expected, PhotoCaptureDate.resolve(0, "PXL_20260119_184146123.jpg", utc))
    }

    @Test
    fun `a dashed screenshot name resolves`() {
        // 2024-01-01 12:00:00 UTC
        assertEquals(1_704_110_400_000L,
            PhotoCaptureDate.resolve(null, "Screenshot_2024-01-01-12-00-00.png", utc))
    }

    @Test
    fun `the local offset is taken out so the wall clock reading is kept`() {
        val utcValue = PhotoCaptureDate.resolve(null, "20260119_184146.jpg", 0)
        val plusTwo = PhotoCaptureDate.resolve(null, "20260119_184146.jpg", 2 * 3_600_000)
        assertEquals(2 * 3_600_000L, utcValue - plusTwo)
    }

    @Test
    fun `a name with no date at all gives zero rather than a guess`() {
        assertEquals(0L, PhotoCaptureDate.resolve(null, "holiday.jpg", utc))
        assertEquals(0L, PhotoCaptureDate.resolve(null, null, utc))
    }

    @Test
    fun `an impossible date in the name is refused`() {
        assertEquals(0L, PhotoCaptureDate.resolve(null, "20260230_120000.jpg", utc))
        assertEquals(0L, PhotoCaptureDate.resolve(null, "20261399_120000.jpg", utc))
    }

    @Test
    fun `a leap day is handled`() {
        // 2024-02-29 00:00:00 UTC
        assertEquals(1_709_164_800_000L, PhotoCaptureDate.resolve(null, "20240229_000000.jpg", utc))
    }
}

/** The ledger is the hash cache and the source of every tombstone. */
class PhotoLedgerCodecTest {

    private fun row(key: String, sha: String? = "aa") = PhotoLedgerRow(
        key = key,
        size = 100,
        captureAt = 200,
        dateModified = 300,
        generation = 400,
        mediaStoreId = 500,
        sha256 = sha,
        attempts = 1,
        skipReason = null,
    )

    @Test
    fun `rows survive a round trip`() {
        val rows = listOf(row("DCIM/Camera/a.jpg"), row("DCIM/Camera/b.jpg", sha = null))
        assertEquals(rows, PhotoLedgerCodec.decode(PhotoLedgerCodec.encode(rows)))
    }

    @Test
    fun `an exclusion reason survives`() {
        val rows = listOf(row("k").copy(skipReason = PhotoExclusion.SIZE))
        assertEquals(PhotoExclusion.SIZE, PhotoLedgerCodec.decode(PhotoLedgerCodec.encode(rows))[0].skipReason)
    }

    @Test
    fun `a name with a tab in it does not break the columns`() {
        val rows = listOf(row("DCIM/Camera/we\tird\\name.jpg"))
        assertEquals(rows, PhotoLedgerCodec.decode(PhotoLedgerCodec.encode(rows)))
    }

    /**
     * The failure that actually happens: the process died mid write. Losing the
     * last row costs one file hashed again; refusing the whole file would erase
     * every tombstone the phone still owes the Mac.
     */
    @Test
    fun `a truncated last line loses only that line`() {
        val text = PhotoLedgerCodec.encode(listOf(row("a"), row("b"))).dropLast(12)
        val decoded = PhotoLedgerCodec.decode(text)
        assertEquals(listOf("a"), decoded.map { it.key })
    }

    @Test
    fun `an empty ledger decodes to nothing`() {
        assertTrue(PhotoLedgerCodec.decode("").isEmpty())
        assertTrue(PhotoLedgerCodec.decode(PhotoLedgerCodec.encode(emptyList())).isEmpty())
    }

    @Test
    fun `unknown extra columns are tolerated`() {
        val text = PhotoLedgerCodec.encode(listOf(row("a"))).trimEnd() + "\tsomething-new\n"
        assertEquals(1, PhotoLedgerCodec.decode(text).size)
    }
}

/** Hashing 46 GB once is acceptable; hashing it every half hour is not. */
class PhotoHashPolicyTest {

    private val cached = PhotoLedgerRow(
        key = "k", size = 100, captureAt = 200, dateModified = 300,
        generation = 400, mediaStoreId = 500, sha256 = "aa",
    )

    @Test
    fun `an unchanged file is not hashed again`() {
        assertTrue(!PhotoHashPolicy.needsHash(cached, 100, 300, 400))
    }

    @Test
    fun `a file with no cached hash is hashed`() {
        assertTrue(PhotoHashPolicy.needsHash(null, 100, 300, 400))
        assertTrue(PhotoHashPolicy.needsHash(cached.copy(sha256 = null), 100, 300, 400))
    }

    @Test
    fun `a changed size or modification time triggers a rehash`() {
        assertTrue(PhotoHashPolicy.needsHash(cached, 101, 300, 400))
        assertTrue(PhotoHashPolicy.needsHash(cached, 100, 301, 400))
    }

    @Test
    fun `a bumped generation triggers a rehash`() {
        assertTrue(PhotoHashPolicy.needsHash(cached, 100, 300, 401))
    }

    /**
     * Below API 30 there is no generation column and the value arrives as zero.
     * Reading that as a change would rehash the whole library on every cycle.
     */
    @Test
    fun `an unreported generation is not treated as a change`() {
        assertTrue(!PhotoHashPolicy.needsHash(cached, 100, 300, 0))
    }
}

/** Tombstones are assertions, and an untrustworthy scan asserts nothing. */
class PhotoTombstonesTest {

    @Test
    fun `what left the folder is reported`() {
        val gone = PhotoTombstones.goneKeys(
            ledger = listOf("a", "b", "c"), present = listOf("a", "c"), scanComplete = true,
        )
        assertEquals(listOf("b"), gone)
    }

    @Test
    fun `nothing is reported when the scan cannot be trusted`() {
        val gone = PhotoTombstones.goneKeys(
            ledger = listOf("a", "b", "c"), present = emptyList(), scanComplete = false,
        )
        assertTrue(gone.isEmpty())
    }

    /**
     * A trusted scan of an emptied folder does report everything - that is a real
     * deletion. The Mac still has the ratio guard behind this, which is where an
     * unexpected mass deletion is stopped rather than here.
     */
    @Test
    fun `an emptied folder does report everything when the scan is trusted`() {
        val gone = PhotoTombstones.goneKeys(
            ledger = listOf("a", "b"), present = emptyList(), scanComplete = true,
        )
        assertEquals(listOf("a", "b"), gone)
    }

    @Test
    fun `a new file on the phone is not a tombstone`() {
        val gone = PhotoTombstones.goneKeys(
            ledger = listOf("a"), present = listOf("a", "new"), scanComplete = true,
        )
        assertTrue(gone.isEmpty())
    }
}

/** The typed start date, both ways round. */
class PhotoDateTest {

    private val utc = 0

    @Test
    fun `a date is read as midnight that day`() {
        // 2026-01-19 00:00:00 UTC
        assertEquals(1_768_780_800_000L, PhotoDate.parse("2026-01-19", utc))
    }

    @Test
    fun `the local offset is honoured so the day is the day you meant`() {
        val plusTwo = 2 * 3_600_000
        assertEquals(1_768_780_800_000L - plusTwo, PhotoDate.parse("2026-01-19", plusTwo))
    }

    @Test
    fun `nonsense is refused rather than guessed at`() {
        assertNull(PhotoDate.parse("", utc))
        assertNull(PhotoDate.parse("19-01-2026", utc))
        assertNull(PhotoDate.parse("2026-13-01", utc))
        assertNull(PhotoDate.parse("2026-02-30", utc))
        assertNull(PhotoDate.parse(null, utc))
    }

    @Test
    fun `surrounding spaces do not matter`() {
        assertEquals(PhotoDate.parse("2026-01-19", utc), PhotoDate.parse("  2026-01-19 ", utc))
    }

    @Test
    fun `formatting is the inverse of parsing`() {
        for (text in listOf("2026-01-19", "2024-02-29", "1999-12-31", "2000-01-01")) {
            val millis = PhotoDate.parse(text, utc)!!
            assertEquals(text, PhotoDate.format(millis, utc))
        }
    }

    @Test
    fun `nothing stored shows as nothing`() {
        assertEquals("", PhotoDate.format(0, utc))
    }
}

/** Paging exists so that a truncated manifest cannot look complete. */
class PhotoManifestPagerTest {

    private fun items(count: Int) =
        (1..count).map { PhotoItem("DCIM/Camera/$it.jpg", it.toLong(), 100, sha256 = "h$it") }

    @Test
    fun `every page carries the total count not its own size`() {
        val pages = PhotoManifestPager.paginate(items(1200), perPage = 500)
        assertEquals(3, pages.size)
        assertTrue(pages.all { it.count == 1200 })
        assertTrue(pages.all { it.pages == 3 })
        assertEquals(listOf(1, 2, 3), pages.map { it.page })
        assertEquals(1200, pages.sumOf { it.items.size })
    }

    @Test
    fun `an empty folder is one empty page not no pages`() {
        val pages = PhotoManifestPager.paginate(emptyList())
        assertEquals(1, pages.size)
        assertEquals(0, pages.first().count)
        assertTrue(pages.first().items.isEmpty())
    }

    @Test
    fun `a byte budget splits a page before the item limit does`() {
        val pages = PhotoManifestPager.paginate(items(100), perPage = 500, maxBytes = 400)
        assertTrue(pages.size > 1)
        assertTrue(pages.all { it.count == 100 })
        assertEquals(100, pages.sumOf { it.items.size })
    }

    @Test
    fun `one item larger than the budget still gets a page of its own`() {
        val pages = PhotoManifestPager.paginate(items(2), perPage = 500, maxBytes = 1)
        assertEquals(2, pages.size)
        assertEquals(2, pages.sumOf { it.items.size })
    }

    @Test
    fun `nothing is lost or reordered`() {
        val all = items(37)
        val pages = PhotoManifestPager.paginate(all, perPage = 10)
        assertEquals(all.map { it.key }, pages.flatMap { it.items }.map { it.key })
    }
}

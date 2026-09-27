package pl.wojas.macdroidsync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The messages payload and the rules that shape a page, see PROTOCOL.md section 9. */
class SmsTest {

    @Test
    fun `the payload rides inside a message`() {
        val payload = SmsPayload(
            requestId = "r1",
            threadId = 7,
            more = true,
            messages = listOf(
                SmsMessage(
                    id = "m3",
                    date = 1_000,
                    fromMe = false,
                    text = "hi",
                    mms = true,
                    images = listOf(SmsImage(partId = "12", mime = "image/jpeg", width = 640, height = 480)),
                    address = "+48600100200",
                ),
            ),
            threads = listOf(SmsThread(id = 7, addresses = listOf("+48600100200"), name = "Anna", date = 1_000, unread = 2, photo = "55")),
            photo = "55",
        )
        val parsed = Message.parse(Message(type = MessageType.SMS_THREAD, sms = payload).toBytes())
        assertEquals(payload, parsed.sms)
    }

    @Test
    fun `wire keys are the documented ones`() {
        val json = SmsPayload(requestId = "r", threadId = 1, partId = "5", state = "sent").toJson()
        assertEquals("r", json.getString("requestId"))
        assertEquals(1L, json.getLong("threadId"))
        assertEquals("5", json.getString("partId"))
        assertEquals("sent", json.getString("state"))
        assertFalse(json.has("messages"))
    }

    @Test
    fun `a page merges both tables and keeps the newest`() {
        val sms = listOf(message("s3", 30), message("s2", 20), message("s1", 10))
        val mms = listOf(message("m1", 25), message("m0", 5))
        val (page, more) = SmsRules.page(sms, mms, limit = 3)
        assertEquals(listOf("s2", "m1", "s3"), page.map { it.id })
        assertTrue(more)
    }

    @Test
    fun `a page that holds everything has no more`() {
        val (page, more) = SmsRules.page(listOf(message("s1", 10)), emptyList(), limit = 5)
        assertEquals(1, page.size)
        assertFalse(more)
    }

    @Test
    fun `status words follow the provider's columns`() {
        assertNull(SmsRules.smsStatus(type = 1, status = -1))
        assertEquals("delivered", SmsRules.smsStatus(type = 2, status = 0))
        assertEquals("sent", SmsRules.smsStatus(type = 2, status = -1))
        assertEquals("failed", SmsRules.smsStatus(type = 5, status = -1))
        assertEquals("pending", SmsRules.smsStatus(type = 4, status = -1))
        assertEquals("sent", SmsRules.mmsStatus(box = 2))
        assertNull(SmsRules.mmsStatus(box = 1))
    }

    @Test
    fun `snippets are flattened and clipped`() {
        assertEquals("a b", SmsRules.snippet(" a\n  b "))
        assertNull(SmsRules.snippet("  "))
        assertEquals(SmsRules.MAX_SNIPPET, SmsRules.snippet("x".repeat(500))!!.length)
    }

    @Test
    fun `only numbers take a reply`() {
        assertTrue(SmsRules.canReply("+48 600 100 200"))
        assertFalse(SmsRules.canReply("BANK"))
    }

    private fun message(id: String, date: Long) = SmsMessage(id = id, date = date, fromMe = false)
}

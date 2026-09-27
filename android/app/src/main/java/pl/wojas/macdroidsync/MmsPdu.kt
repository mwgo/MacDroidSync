package pl.wojas.macdroidsync

import java.io.ByteArrayOutputStream

/**
 * Builds the M-Send.req PDU that SmsManager.sendMultimediaMessage hands to the
 * carrier. Android has no public encoder, so this is the part of the OMA MMS
 * encapsulation (WAP-209, WAP-230) that one picture and some text need, and
 * nothing more.
 *
 * The body is multipart/related with a SMIL part first, the layout every
 * messaging app understands: the picture above, the text below.
 */
object MmsPdu {

    class Part(val contentType: String, val name: String, val data: ByteArray)

    fun sendRequest(to: String, text: String?, image: ByteArray?, imageMime: String = "image/jpeg"): ByteArray {
        val parts = mutableListOf<Part>()
        image?.let { parts += Part(imageMime, "image.jpg", it) }
        text?.takeIf { it.isNotEmpty() }?.let { parts += Part("text/plain", "text.txt", it.toByteArray(Charsets.UTF_8)) }
        parts.add(0, Part("application/smil", "smil.xml", smil(image != null, !text.isNullOrEmpty()).toByteArray(Charsets.UTF_8)))

        val out = ByteArrayOutputStream()
        out.write(MESSAGE_TYPE); out.write(M_SEND_REQ)
        out.write(TRANSACTION_ID); textString(out, "T" + System.currentTimeMillis().toString(16))
        out.write(MMS_VERSION); out.write(0x80 or 0x12)
        // From: insert-address-token, the carrier fills in this phone's number.
        out.write(FROM); out.write(0x01); out.write(0x81)
        out.write(TO); textString(out, address(to))
        out.write(CONTENT_TYPE); relatedContentType(out)
        multipart(out, parts)
        return out.toByteArray()
    }

    /** A number becomes `+48600100200/TYPE=PLMN`; anything else is left for the carrier. */
    fun address(to: String): String {
        val digits = to.filter { it.isDigit() || it == '+' }
        return if (digits.count { it.isDigit() } >= 3) "$digits/TYPE=PLMN" else to
    }

    private fun smil(hasImage: Boolean, hasText: Boolean): String {
        val body = buildString {
            if (hasImage) append("<img src=\"image.jpg\" region=\"Image\"/>")
            if (hasText) append("<text src=\"text.txt\" region=\"Text\"/>")
        }
        return "<smil><head><layout><root-layout/>" +
            "<region id=\"Image\" top=\"0\" left=\"0\" height=\"80%\" width=\"100%\" fit=\"meet\"/>" +
            "<region id=\"Text\" top=\"80%\" left=\"0\" height=\"20%\" width=\"100%\" fit=\"scroll\"/>" +
            "</layout></head><body><par dur=\"5000ms\">$body</par></body></smil>"
    }

    /** multipart/related; start=<smil>; type=application/smil */
    private fun relatedContentType(out: ByteArrayOutputStream) {
        val value = ByteArrayOutputStream()
        value.write(0x80 or 0x33)                       // multipart/related
        value.write(PARAM_START); textString(value, "<smil>")
        value.write(PARAM_TYPE); textString(value, "application/smil")
        valueLength(out, value.size())
        value.writeTo(out)
    }

    private fun multipart(out: ByteArrayOutputStream, parts: List<Part>) {
        uintvar(out, parts.size.toLong())
        for (part in parts) {
            val headers = ByteArrayOutputStream()
            partContentType(headers, part.contentType)
            headers.write(PART_CONTENT_LOCATION); textString(headers, part.name)
            headers.write(PART_CONTENT_ID)
            headers.write(0x22)                         // quoted string
            val id = if (part.contentType == "application/smil") "<smil>" else "<${part.name}>"
            headers.write(id.toByteArray(Charsets.US_ASCII)); headers.write(0)
            uintvar(out, headers.size().toLong())
            uintvar(out, part.data.size.toLong())
            headers.writeTo(out)
            out.write(part.data)
        }
    }

    private fun partContentType(out: ByteArrayOutputStream, type: String) {
        when (type) {
            "text/plain" -> {
                // text/plain; charset=utf-8
                out.write(0x03); out.write(0x80 or 0x03); out.write(PARAM_CHARSET); out.write(0x80 or 106)
            }
            "image/jpeg" -> out.write(0x80 or 0x1E)
            "image/png" -> out.write(0x80 or 0x20)
            "image/gif" -> out.write(0x80 or 0x1D)
            else -> textString(out, type)
        }
    }

    private fun textString(out: ByteArrayOutputStream, text: String) {
        val bytes = text.toByteArray(Charsets.UTF_8)
        // A text string whose first octet is above 127 has to be quoted.
        if (bytes.isNotEmpty() && (bytes[0].toInt() and 0xFF) > 127) out.write(0x7F)
        out.write(bytes)
        out.write(0)
    }

    fun valueLength(out: ByteArrayOutputStream, length: Int) {
        if (length < 31) {
            out.write(length)
        } else {
            out.write(31)
            uintvar(out, length.toLong())
        }
    }

    fun uintvar(out: ByteArrayOutputStream, value: Long) {
        var rest = value
        val groups = ArrayList<Int>()
        do {
            groups.add((rest and 0x7F).toInt())
            rest = rest ushr 7
        } while (rest > 0)
        for (index in groups.indices.reversed()) {
            out.write(if (index > 0) groups[index] or 0x80 else groups[index])
        }
    }

    private const val MESSAGE_TYPE = 0x8C
    private const val M_SEND_REQ = 0x80
    private const val TRANSACTION_ID = 0x98
    private const val MMS_VERSION = 0x8D
    private const val FROM = 0x89
    private const val TO = 0x97
    private const val CONTENT_TYPE = 0x84
    private const val PARAM_CHARSET = 0x81
    private const val PARAM_TYPE = 0x89
    private const val PARAM_START = 0x8A
    private const val PART_CONTENT_LOCATION = 0x8E
    private const val PART_CONTENT_ID = 0xC0
}

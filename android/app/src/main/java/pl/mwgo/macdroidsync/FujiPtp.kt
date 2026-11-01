package pl.mwgo.macdroidsync

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.net.SocketFactory

/**
 * PTP over the camera's own Wi-Fi, the way a Fujifilm camera speaks it: a PTP/IP
 * init packet with Fuji's protocol version, then USB-style PTP containers on the
 * same TCP connection. One transaction at a time; every call blocks.
 */
class FujiPtp private constructor(private val socket: Socket) {

    private val input = DataInputStream(socket.getInputStream())
    private val output: OutputStream = socket.getOutputStream()
    private var transaction = 1

    class Response(val code: Int, val params: List<Int>, val data: ByteArray)

    class PtpException(message: String, val code: Int = 0) : IOException(message)

    /** Standard ObjectInfo dataset, reduced to what is used here. */
    data class ObjectInfo(
        val handle: Int,
        val format: Int,
        val size: Long,
        val width: Int,
        val height: Int,
        val filename: String,
        val captureDate: String,
    ) {
        val isJpeg: Boolean get() = format == FORMAT_JPEG || filename.endsWith(".JPG", ignoreCase = true)
    }

    /** Every operation and its answer, for the log. */
    var trace: ((String) -> Unit)? = null

    fun transact(code: Int, vararg params: Int, out: ByteArray? = null): Response {
        val id = transaction++
        trace?.invoke("-> 0x%04X %s%s".format(code, params.joinToString(" ") { "0x%X".format(it) }, out?.let { " +${it.size} B" } ?: ""))
        output.write(command(CONTAINER_COMMAND, code, id, params))
        if (out != null) output.write(container(CONTAINER_DATA, code, id, out))
        output.flush()
        val data = ByteArrayOutputStream()
        while (true) {
            val length = readU32()
            val type = readU16()
            val responseCode = readU16()
            readU32()
            val body = ByteArray(length - HEADER).also { input.readFully(it) }
            when (type) {
                CONTAINER_DATA -> data.write(body)
                CONTAINER_RESPONSE -> {
                    val buffer = ByteBuffer.wrap(body).order(ByteOrder.LITTLE_ENDIAN)
                    val responseParams = List(body.size / 4) { buffer.int }
                    trace?.invoke("<- 0x%04X data %d B".format(responseCode, data.size()))
                    return Response(responseCode, responseParams, data.toByteArray())
                }
                else -> throw PtpException("Unexpected container type $type")
            }
        }
    }

    /** Like [transact], but anything other than OK is an exception. */
    fun call(code: Int, vararg params: Int, out: ByteArray? = null): Response {
        val response = transact(code, *params, out = out)
        if (response.code != RC_OK) {
            throw PtpException("Operation 0x%04X answered 0x%04X".format(code, response.code), response.code)
        }
        return response
    }

    fun getProperty(property: Int): ByteArray = call(OC_GET_DEVICE_PROP_VALUE, property).data

    fun getPropertyInt(property: Int): Int = le(getProperty(property)).let { buffer ->
        when (buffer.remaining()) {
            0 -> 0
            1 -> buffer.get().toInt() and 0xFF
            2, 3 -> buffer.short.toInt() and 0xFFFF
            else -> buffer.int
        }
    }

    fun setProperty16(property: Int, value: Int) {
        call(OC_SET_DEVICE_PROP_VALUE, property, out = le(2).putShort(value.toShort()).array())
    }

    fun setProperty(property: Int, value: ByteArray) {
        call(OC_SET_DEVICE_PROP_VALUE, property, out = value)
    }

    /** Property changes since the last call, as code to value. */
    fun events(): Map<Int, Int> = parseEvents(getProperty(DPC_EVENTS))

    fun objectInfo(handle: Int): ObjectInfo = parseObjectInfo(handle, call(OC_GET_OBJECT_INFO, handle).data)

    fun thumbnail(handle: Int): ByteArray = call(OC_GET_THUMB, handle).data

    fun partial(handle: Int, offset: Long, size: Int): ByteArray =
        call(OC_GET_PARTIAL_OBJECT, handle, offset.toInt(), size).data

    /** How long a reply may take; the camera may be waiting for a tap on its own screen. */
    var timeoutMs: Int
        get() = socket.soTimeout
        set(value) {
            socket.soTimeout = value
        }

    fun close() {
        runCatching { transact(OC_CLOSE_SESSION) }
        runCatching { socket.close() }
    }

    private fun readU32(): Int = Integer.reverseBytes(input.readInt())

    private fun readU16(): Int = java.lang.Short.reverseBytes(input.readShort()).toInt() and 0xFFFF

    companion object {
        const val HOST = "192.168.0.1"
        const val PORT = 55740

        const val OC_OPEN_SESSION = 0x1002
        const val OC_CLOSE_SESSION = 0x1003
        const val OC_GET_OBJECT_INFO = 0x1008
        const val OC_GET_THUMB = 0x100A
        const val OC_GET_DEVICE_PROP_VALUE = 0x1015
        const val OC_SET_DEVICE_PROP_VALUE = 0x1016
        const val OC_GET_PARTIAL_OBJECT = 0x101B
        const val OC_FUJI_IMPORT_FOLDERS = 0x9050
        const val OC_FUJI_IMPORT_DATES = 0x9053
        const val OC_FUJI_EXTENSION_INFO = 0x9054
        const val OC_FUJI_EXTENSION_THUMB = 0x9055
        /** What the extension operations take for the newest picture. */
        const val LATEST = 0x10000001
        const val DPC_UNKNOWN_D22B = 0xD22B

        const val RC_OK = 0x2001
        const val RC_BUSY = 0x2019
        const val RC_SESSION_OPEN = 0x201E

        /** Changed properties, polled: a count, then code and value pairs. */
        const val DPC_EVENTS = 0xD212
        /** What a full size download is: 2 the original, 1 a resized copy. */
        const val DPC_COMPRESS = 0xD226
        const val DPC_CORRECT_SIZE = 0xD227
        const val DPC_OBJECT_COUNT = 0xD620
        const val DPC_OBJECT_HANDLES = 0xD621
        /** The client's mode; 20 is XApp viewing the camera's pictures. */
        const val DPC_CLIENT_STATE = 0xDF01
        const val DPC_PHOTO_VIEW_VERSION = 0xDF28
        const val CLIENT_IMAGE_VIEW_XAPP = 20

        const val FORMAT_JPEG = 0x3801
        const val CHUNK = 0x100000

        private const val HEADER = 12
        private const val CONTAINER_COMMAND = 1
        private const val CONTAINER_DATA = 2
        private const val CONTAINER_RESPONSE = 3
        private const val INIT_COMMAND_REQUEST = 1
        private const val INIT_FAIL = 5
        private const val FUJI_PROTOCOL_VERSION = 0x8F53E4F2.toInt()
        private val GUID = intArrayOf(0x5D48A5AD, 0x0B7FB287, 0xD0DED5D3.toInt(), 0)

        /**
         * Connects, introduces this phone by [name] (the name the camera was
         * paired with, or it answers busy) and opens session 1.
         */
        fun open(factory: SocketFactory, name: String, timeoutMs: Int = 7_000): FujiPtp {
            val socket = factory.createSocket()
            socket.connect(InetSocketAddress(HOST, PORT), 5_000)
            socket.soTimeout = timeoutMs
            socket.tcpNoDelay = true
            val stream = DataInputStream(socket.getInputStream())
            socket.getOutputStream().apply { write(initPacket(name)); flush() }
            val length = Integer.reverseBytes(stream.readInt())
            val reply = ByteArray(length - 4).also { stream.readFully(it) }
            val type = le(reply).int
            if (type == INIT_FAIL) {
                val reason = if (reply.size >= 8) le(reply).apply { position(4) }.int else 0
                socket.close()
                throw PtpException("The camera refused the connection (0x%X)".format(reason), reason)
            }
            val ptp = FujiPtp(socket)
            // Fuji needs a moment between the init and the session.
            Thread.sleep(50)
            val session = ptp.transact(OC_OPEN_SESSION, 1)
            if (session.code != RC_OK && session.code != RC_SESSION_OPEN) {
                ptp.close()
                throw PtpException("OpenSession answered 0x%04X".format(session.code), session.code)
            }
            return ptp
        }

        fun initPacket(name: String): ByteArray {
            val buffer = le(82).putInt(82).putInt(INIT_COMMAND_REQUEST).putInt(FUJI_PROTOCOL_VERSION)
            GUID.forEach { buffer.putInt(it) }
            val chars = name.take(26).toByteArray(Charsets.UTF_16LE)
            buffer.put(chars)
            return buffer.array()
        }

        fun command(type: Int, code: Int, id: Int, params: IntArray): ByteArray {
            val buffer = le(HEADER + params.size * 4)
                .putInt(HEADER + params.size * 4).putShort(type.toShort()).putShort(code.toShort()).putInt(id)
            params.forEach { buffer.putInt(it) }
            return buffer.array()
        }

        fun container(type: Int, code: Int, id: Int, payload: ByteArray): ByteArray =
            le(HEADER + payload.size)
                .putInt(HEADER + payload.size).putShort(type.toShort()).putShort(code.toShort()).putInt(id)
                .put(payload).array()

        fun parseEvents(data: ByteArray): Map<Int, Int> {
            if (data.size < 2) return emptyMap()
            val buffer = le(data)
            val count = buffer.short.toInt() and 0xFFFF
            val events = LinkedHashMap<Int, Int>()
            repeat(count) {
                if (buffer.remaining() < 6) return events
                events[buffer.short.toInt() and 0xFFFF] = buffer.int
            }
            return events
        }

        /** A PTP array: a uint32 count, then that many uint32 values. */
        fun parseHandles(data: ByteArray): List<Int> {
            if (data.size < 4) return emptyList()
            val buffer = le(data)
            val count = buffer.int
            return List(minOf(count, buffer.remaining() / 4)) { buffer.int }
        }

        fun parseObjectInfo(handle: Int, data: ByteArray): ObjectInfo {
            val buffer = le(data)
            buffer.int // storage
            val format = buffer.short.toInt() and 0xFFFF
            buffer.short // protection
            val size = buffer.int.toLong() and 0xFFFFFFFFL
            buffer.short // thumb format
            buffer.int // thumb size
            buffer.int // thumb width
            buffer.int // thumb height
            val width = buffer.int
            val height = buffer.int
            buffer.int // bit depth
            buffer.int // parent
            buffer.short // association type
            buffer.int // association description
            buffer.int // sequence
            val filename = buffer.ptpString()
            val captureDate = buffer.ptpString()
            return ObjectInfo(handle, format, size, width, height, filename, captureDate)
        }

        private fun ByteBuffer.ptpString(): String {
            if (!hasRemaining()) return ""
            val chars = get().toInt() and 0xFF
            if (chars == 0) return ""
            val bytes = ByteArray(minOf(chars * 2, remaining())).also { get(it) }
            return String(bytes, Charsets.UTF_16LE).trimEnd('\u0000')
        }

        private fun le(size: Int): ByteBuffer = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)

        private fun le(data: ByteArray): ByteBuffer = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
    }
}

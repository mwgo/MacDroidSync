package pl.wojas.macdroidsync

import android.util.Base64
import android.util.Log
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.OutputStream
import java.net.Socket

/**
 * One TCP session with the Mac: handshake, framing and the blocking read loop.
 * Every method except [close] and [sendClipboard] runs on the caller's thread,
 * which is always an IO dispatcher thread.
 */
class PeerConnection(
    private val socket: Socket,
    pairingCode: String,
    private val deviceName: String,
    private val deviceId: String,
) {
    interface Listener {
        fun onAuthenticated(macName: String)
        fun onClipboard(text: String)
        fun onClipboardRequested()
        fun onPing(macName: String)
    }

    private val codec = FrameCodec(pairingCode)
    private val input = DataInputStream(BufferedInputStream(socket.getInputStream()))
    private val output: OutputStream = socket.getOutputStream()
    private val sendLock = Any()

    @Volatile
    var isAuthenticated = false
        private set

    @Volatile
    private var lastSendAt = 0L

    private var macName: String = "Mac"

    /** Reads frames until the peer closes the socket or an error occurs. */
    fun runLoop(listener: Listener) {
        while (!socket.isClosed) {
            val frame = readFrame() ?: break
            handle(frame.first, frame.second, listener)
        }
    }

    fun sendClipboard(text: String) {
        send(Message(type = MessageType.CLIPBOARD, seq = codec.nextSequence(), text = text))
    }

    fun requestClipboard() {
        send(Message(type = MessageType.REQUEST_CLIPBOARD, seq = codec.nextSequence()))
    }

    /** Keeps the session alive while nothing else is being sent. */
    fun sendHeartbeatIfIdle() {
        if (!isAuthenticated) return
        if (System.currentTimeMillis() - lastSendAt < Wire.HEARTBEAT_INTERVAL_MS) return
        send(Message(type = MessageType.HEARTBEAT, seq = codec.nextSequence()))
    }

    fun close() {
        runCatching { socket.close() }
    }

    // region Framing

    private fun readFrame(): Pair<Byte, ByteArray>? {
        val header = ByteArray(4)
        var read = 0
        while (read < 4) {
            val count = input.read(header, read, 4 - read)
            if (count < 0) return null
            read += count
        }
        val length = ((header[0].toInt() and 0xFF) shl 24) or
            ((header[1].toInt() and 0xFF) shl 16) or
            ((header[2].toInt() and 0xFF) shl 8) or
            (header[3].toInt() and 0xFF)
        if (length < 1 || length > Wire.MAX_FRAME_SIZE) {
            throw ProtocolException("Frame of $length bytes is out of range")
        }
        val payload = ByteArray(length)
        input.readFully(payload)
        return payload[0] to payload.copyOfRange(1, payload.size)
    }

    private fun send(message: Message) {
        val frame = Framing.frame(Wire.KIND_ENCRYPTED, codec.seal(message))
        synchronized(sendLock) {
            output.write(frame)
            output.flush()
        }
        lastSendAt = System.currentTimeMillis()
        Log.d(TAG, "-> ${message.type} seq=${message.seq}")
    }

    // endregion

    private fun handle(kind: Byte, body: ByteArray, listener: Listener) {
        if (kind == Wire.KIND_PLAINTEXT) {
            val message = Message.parse(body)
            if (isAuthenticated || message.type != MessageType.CHALLENGE) {
                throw ProtocolException("Unexpected plaintext ${message.type}")
            }
            macName = message.device ?: "Mac"
            val challenge = message.challenge
                ?: throw ProtocolException("Challenge without a nonce")
            Log.d(TAG, "<- challenge from $macName")
            // Sealing the echoed challenge proves we know the pairing code.
            send(
                Message(
                    type = MessageType.HELLO,
                    seq = codec.nextSequence(),
                    challenge = challenge,
                    device = deviceName,
                    deviceId = deviceId,
                )
            )
            return
        }

        val message = codec.open(body)
        Log.d(TAG, "<- ${message.type} seq=${message.seq}")

        when (message.type) {
            MessageType.HELLO_ACK -> {
                isAuthenticated = true
                macName = message.device ?: macName
                listener.onAuthenticated(macName)
            }
            MessageType.CLIPBOARD -> {
                send(Message(type = MessageType.CLIPBOARD_ACK, seq = codec.nextSequence()))
                message.text?.takeIf { it.isNotEmpty() }?.let(listener::onClipboard)
            }
            MessageType.CLIPBOARD_ACK -> Unit
            MessageType.REQUEST_CLIPBOARD -> listener.onClipboardRequested()
            MessageType.PING -> {
                send(Message(type = MessageType.PONG, seq = codec.nextSequence(), token = message.token))
                listener.onPing(macName)
            }
            MessageType.PONG, MessageType.HEARTBEAT -> Unit
            MessageType.BYE -> {
                Log.i(TAG, "Mac said goodbye: ${message.reason}")
                close()
            }
            else -> Log.i(TAG, "Ignoring unknown message type ${message.type}")
        }
    }

    companion object {
        private const val TAG = Prefs.TAG

        /** Only used by the unit tests, mirrors the base64 helper of the Mac side. */
        fun encodeChallenge(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)
    }
}

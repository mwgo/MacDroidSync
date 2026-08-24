package pl.wojas.macdroidsync

import android.util.Base64
import android.util.Log
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.OutputStream
import java.net.Socket
import java.util.Collections

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
    /** State of the presence beacon at handshake time, see [sendPresence]. */
    private val beaconEnabled: Boolean = false,
) {
    interface Listener {
        fun onAuthenticated(macName: String)
        fun onClipboard(text: String)
        fun onClipboardRequested()
        fun onPing(macName: String)
        /** Verdict of the Mac on a file we sent; [path] is set when [ok]. */
        fun onFileAck(fileId: String, ok: Boolean, path: String?, reason: String?)
        /** Progress of a file arriving from the Mac. */
        fun onIncomingProgress(name: String, received: Long, total: Long)
        fun onFileReceived(name: String, saved: IncomingFiles.Saved)
        fun onFileRefused(name: String, reason: String)

        /**
         * The Mac asking about photos: [keys] is the batch it wants, and null
         * means "build a manifest now" - the same request with nothing to ask
         * for yet, which is what its manual sync sends.
         */
        fun onPhotoPull(keys: List<String>?, manifestId: String?)
    }

    /** Where files coming from the Mac are written; without it they are refused. */
    var fileSink: FileSink? = null

    private val codec = FrameCodec(pairingCode)
    private val input = DataInputStream(BufferedInputStream(socket.getInputStream()))
    private val output: OutputStream = socket.getOutputStream()
    private val sendLock = Any()

    /** Files the Mac turned down, so the remaining chunks are not sent. */
    private val refused = Collections.synchronizedSet(mutableSetOf<String>())

    private var incoming: FileOffer? = null
    private var lastProgressAt = 0L

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

    /**
     * Tells the Mac whether the presence beacon is on. Without this the Mac
     * could not tell "the user switched the feature off" apart from "the user
     * walked away", and would lock the screen of someone sitting right there.
     */
    fun sendPresence(enabled: Boolean) {
        send(Message(type = MessageType.PRESENCE, seq = codec.nextSequence(), beacon = enabled))
    }

    /**
     * Asks the Mac to lock its screen now. Independent of the presence beacon:
     * the button works whether or not the automatic locking is switched on.
     */
    fun sendLockRequest() {
        send(Message(type = MessageType.LOCK, seq = codec.nextSequence()))
    }

    fun sendClipboard(text: String) {
        send(Message(type = MessageType.CLIPBOARD, seq = codec.nextSequence(), text = text))
    }

    fun requestClipboard() {
        send(Message(type = MessageType.REQUEST_CLIPBOARD, seq = codec.nextSequence()))
    }

    /**
     * Streams one staged file to the Mac: offer, chunks, end. Blocking, so it
     * belongs on an IO thread, and it must not run on the thread that owns
     * [runLoop] because the file-ack arrives there.
     *
     * Returns false when the Mac turned the file down mid flight, in which case
     * the remaining chunks are never sent.
     */
    fun sendFile(item: Outbox.Item, fileId: String, onProgress: (Long, Long) -> Unit): Boolean {
        val size = item.size
        val checksum = Outbox.sha256(item.file)
        send(
            Message(
                type = MessageType.FILE_OFFER,
                seq = codec.nextSequence(),
                fileId = fileId,
                name = item.name,
                size = size,
                mime = item.mime,
            )
        )

        var sent = 0L
        item.file.inputStream().use { stream ->
            val buffer = ByteArray(Wire.FILE_CHUNK_BYTES)
            while (true) {
                if (refused.contains(fileId)) return false
                val read = stream.read(buffer)
                if (read < 0) break
                send(
                    Message(
                        type = MessageType.FILE_CHUNK,
                        seq = codec.nextSequence(),
                        fileId = fileId,
                        data = Base64.encodeToString(buffer, 0, read, Base64.NO_WRAP),
                    )
                )
                sent += read
                onProgress(sent, size)
            }
        }
        if (refused.contains(fileId)) return false

        send(
            Message(
                type = MessageType.FILE_END,
                seq = codec.nextSequence(),
                fileId = fileId,
                sha256 = checksum,
            )
        )
        return true
    }

    /** One page of the phone's picture of its camera folder. */
    fun sendPhotoManifest(payload: PhotoPayload, ok: Boolean = true, reason: String? = null) {
        send(
            Message(
                type = MessageType.PHOTO_MANIFEST,
                seq = codec.nextSequence(),
                ok = if (ok) null else false,
                reason = reason,
                photo = payload,
            )
        )
    }

    /**
     * Streams one gallery item straight from MediaStore.
     *
     * Deliberately not [sendFile]: that one works from a staged copy in the cache
     * directory, which would mean copying a 46 GB camera folder through a 512 MiB
     * queue. Here the bytes are read exactly once, the checksum grows as they go
     * past, and it is sent in file-end afterwards - which is the message that
     * carries it anyway.
     *
     * [open] hands back the stream so that the caller can decide about
     * `setRequireOriginal`, which is what keeps the GPS tags in the file, without
     * this class having to know about MediaStore at all.
     */
    fun sendPhoto(
        key: String,
        name: String,
        size: Long,
        mime: String?,
        captureAt: Long,
        fileId: String,
        open: () -> java.io.InputStream,
        onProgress: (Long, Long) -> Unit,
    ): Boolean {
        send(
            Message(
                type = MessageType.FILE_OFFER,
                seq = codec.nextSequence(),
                fileId = fileId,
                name = name,
                size = size,
                mime = mime,
                photo = PhotoPayload(key = key, captureAt = captureAt),
            )
        )

        val digest = java.security.MessageDigest.getInstance("SHA-256")
        var sent = 0L
        open().use { stream ->
            val buffer = ByteArray(Wire.FILE_CHUNK_BYTES)
            while (true) {
                if (refused.contains(fileId)) return false
                val read = stream.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
                send(
                    Message(
                        type = MessageType.FILE_CHUNK,
                        seq = codec.nextSequence(),
                        fileId = fileId,
                        data = Base64.encodeToString(buffer, 0, read, Base64.NO_WRAP),
                    )
                )
                sent += read
                onProgress(sent, size)
            }
        }
        if (refused.contains(fileId)) return false

        send(
            Message(
                type = MessageType.FILE_END,
                seq = codec.nextSequence(),
                fileId = fileId,
                sha256 = digest.digest().joinToString("") { "%02x".format(it) },
            )
        )
        return true
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
                    beacon = beaconEnabled,
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
            MessageType.PONG -> Unit
            // Answered here rather than left to the timer in SyncService. Doze
            // suspends this process for minutes at a stretch - measured at 88
            // seconds while the Mac was still probing every 15 - and no timer in
            // the process runs across that: a coroutine `delay` parks on a clock
            // that stops with the CPU, while the interval it is compared against
            // is wall clock. Reading this frame is proof the CPU is ours right
            // now, so this is the one moment the reply is certain to go out.
            MessageType.HEARTBEAT -> sendHeartbeatIfIdle()
            MessageType.FILE_ACK -> {
                val fileId = message.fileId.orEmpty()
                val ok = message.ok == true
                if (!ok) refused.add(fileId)
                listener.onFileAck(fileId, ok, message.path, message.reason)
            }
            MessageType.PHOTO_PULL -> listener.onPhotoPull(
                message.photo?.keys,
                message.photo?.manifestId,
            )
            MessageType.FILE_OFFER -> handleFileOffer(message, listener)
            MessageType.FILE_CHUNK -> handleFileChunk(message, listener)
            MessageType.FILE_END -> handleFileEnd(message, listener)
            MessageType.BYE -> {
                Log.i(TAG, "Mac said goodbye: ${message.reason}")
                close()
            }
            else -> Log.i(TAG, "Ignoring unknown message type ${message.type}")
        }
    }

    // region Incoming files

    private fun handleFileOffer(message: Message, listener: Listener) {
        val offer = FileOffer(
            id = message.fileId ?: "",
            name = message.name ?: "file",
            size = message.size ?: 0,
            mime = message.mime,
        )
        val sink = fileSink
        if (sink == null) {
            refuse(offer, "this phone has nowhere to save files", listener)
            return
        }
        try {
            sink.begin(offer)
            incoming = offer
            lastProgressAt = 0L
            reportIncomingProgress(sink, offer, listener, force = true)
        } catch (error: Exception) {
            refuse(offer, error.message ?: "the file was refused", listener)
        }
    }

    private fun handleFileChunk(message: Message, listener: Listener) {
        val offer = incoming ?: return
        val sink = fileSink ?: return
        val encoded = message.data
        if (encoded == null) {
            incoming = null
            sink.abort()
            refuse(offer, "malformed chunk", listener)
            return
        }
        try {
            sink.append(Base64.decode(encoded, Base64.DEFAULT))
            reportIncomingProgress(sink, offer, listener)
        } catch (error: Exception) {
            incoming = null
            refuse(offer, error.message ?: "the chunk could not be written", listener)
        }
    }

    private fun handleFileEnd(message: Message, listener: Listener) {
        val offer = incoming ?: return
        val sink = fileSink ?: return
        incoming = null
        try {
            val saved = sink.finish(message.sha256)
            send(
                Message(
                    type = MessageType.FILE_ACK,
                    seq = codec.nextSequence(),
                    fileId = offer.id.ifEmpty { null },
                    name = offer.name,
                    ok = true,
                    path = saved.path,
                )
            )
            listener.onFileReceived(offer.name, saved)
        } catch (error: Exception) {
            refuse(offer, error.message ?: "the file could not be saved", listener)
        }
    }

    /** Tells the Mac to stop sending and why. */
    private fun refuse(offer: FileOffer, reason: String, listener: Listener) {
        Log.w(TAG, "Refused ${offer.name}: $reason")
        send(
            Message(
                type = MessageType.FILE_ACK,
                seq = codec.nextSequence(),
                reason = reason,
                fileId = offer.id.ifEmpty { null },
                name = offer.name,
                ok = false,
            )
        )
        listener.onFileRefused(offer.name, reason)
    }

    /** Throttled, otherwise a fast transfer would rebuild the notification hundreds of times. */
    private fun reportIncomingProgress(sink: FileSink, offer: FileOffer, listener: Listener, force: Boolean = false) {
        val now = System.currentTimeMillis()
        if (!force && now - lastProgressAt < PROGRESS_INTERVAL_MS) return
        lastProgressAt = now
        listener.onIncomingProgress(offer.name, sink.receivedBytes, offer.size)
    }

    // endregion

    companion object {
        private const val TAG = Prefs.TAG
        private const val PROGRESS_INTERVAL_MS = 500L

        /** Only used by the unit tests, mirrors the base64 helper of the Mac side. */
        fun encodeChallenge(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)
    }
}

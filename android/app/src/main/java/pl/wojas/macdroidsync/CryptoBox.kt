package pl.wojas.macdroidsync

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Key derivation and AES-256-GCM sealing, byte compatible with the CryptoKit
 * based macOS implementation. See PROTOCOL.md for the test vectors.
 */
object CryptoBox {
    private val HKDF_SALT = "MacDroidSync/v1".toByteArray(Charsets.UTF_8)
    private val HKDF_INFO = "clipboard-channel".toByteArray(Charsets.UTF_8)
    const val NONCE_LENGTH = 12
    const val TAG_LENGTH = 16

    /** Uppercase, separators removed: "abcd-efgh" and "ABCDEFGH" are the same code. */
    fun normalize(pairingCode: String): String =
        pairingCode.uppercase().filter { it.isLetterOrDigit() }

    fun deriveKey(pairingCode: String): ByteArray =
        hkdfSha256(
            ikm = normalize(pairingCode).toByteArray(Charsets.UTF_8),
            salt = HKDF_SALT,
            info = HKDF_INFO,
            length = 32,
        )

    fun seal(plaintext: ByteArray, key: ByteArray, nonce: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_LENGTH * 8, nonce))
        val sealed = cipher.doFinal(plaintext)
        return nonce + sealed
    }

    fun open(body: ByteArray, key: ByteArray): ByteArray {
        if (body.size <= NONCE_LENGTH + TAG_LENGTH) {
            throw ProtocolException("Sealed body of ${body.size} bytes is too short")
        }
        val nonce = body.copyOfRange(0, NONCE_LENGTH)
        val sealed = body.copyOfRange(NONCE_LENGTH, body.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_LENGTH * 8, nonce))
        return try {
            cipher.doFinal(sealed)
        } catch (error: Exception) {
            throw ProtocolException("Authentication failed - the pairing code does not match")
        }
    }

    fun fingerprint(text: String): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        return digest.digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }

    fun randomBytes(count: Int): ByteArray = ByteArray(count).also { SecureRandom().nextBytes(it) }

    private fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val extract = Mac.getInstance("HmacSHA256")
        extract.init(SecretKeySpec(salt, "HmacSHA256"))
        val prk = extract.doFinal(ikm)

        val expand = Mac.getInstance("HmacSHA256")
        expand.init(SecretKeySpec(prk, "HmacSHA256"))
        val output = ByteArray(length)
        var block = ByteArray(0)
        var offset = 0
        var counter = 1
        while (offset < length) {
            expand.reset()
            expand.update(block)
            expand.update(info)
            expand.update(counter.toByte())
            block = expand.doFinal()
            val take = minOf(block.size, length - offset)
            block.copyInto(output, offset, 0, take)
            offset += take
            counter++
        }
        return output
    }
}

/**
 * Per connection sealing state: an outgoing nonce counter plus replay protection
 * for the sequence numbers seen on the wire.
 */
class FrameCodec(pairingCode: String) {
    private val key = CryptoBox.deriveKey(pairingCode)
    private val noncePrefix = CryptoBox.randomBytes(4)
    private var sendCounter = 0L
    private var lastSeenSeq = 0L
    private var outgoingSeq = 0L

    fun nextSequence(): Long = ++outgoingSeq

    fun seal(message: Message): ByteArray {
        sendCounter++
        val nonce = ByteArray(CryptoBox.NONCE_LENGTH)
        noncePrefix.copyInto(nonce)
        for (index in 0 until 8) {
            nonce[4 + index] = (sendCounter ushr (8 * (7 - index)) and 0xFF).toByte()
        }
        return CryptoBox.seal(message.toBytes(), key, nonce)
    }

    /** Decrypts a frame body and rejects replayed or reordered messages. */
    fun open(body: ByteArray): Message {
        val message = Message.parse(CryptoBox.open(body, key))
        if (message.seq <= lastSeenSeq) {
            throw ProtocolException("Replayed or out of order message (seq ${message.seq})")
        }
        lastSeenSeq = message.seq
        return message
    }
}

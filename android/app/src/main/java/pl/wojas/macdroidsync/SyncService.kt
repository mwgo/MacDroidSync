package pl.wojas.macdroidsync

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Long lived foreground service that owns the connection to the Mac.
 *
 * While disconnected it stays alive on a silent IMPORTANCE_MIN notification (no
 * status bar icon) and retries with a backoff; the retry is also woken up the
 * moment a network becomes available. Once the handshake succeeds the visible
 * notification with the status bar icon and the clipboard action is posted.
 */
class SyncService : Service() {

    private lateinit var prefs: Prefs
    private lateinit var notifications: NotificationCenter
    private lateinit var discovery: Discovery
    private lateinit var connectivity: ConnectivityManager
    private lateinit var ringer: Ringer
    private lateinit var outbox: Outbox
    private lateinit var incomingFiles: IncomingFiles
    private lateinit var beacon: PresenceAdvertiser

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val retryTrigger = Channel<Unit>(Channel.CONFLATED)

    /** file-ack the Mac still owes us, keyed by the id used on the wire. */
    private val pendingAcks = ConcurrentHashMap<String, CompletableDeferred<FileVerdict>>()
    /** How often a queued file has been tried, so a stuck one cannot loop forever. */
    private val attempts = ConcurrentHashMap<String, Int>()

    private var loopJob: Job? = null
    private var drainJob: Job? = null

    @Volatile
    private var connection: PeerConnection? = null

    @Volatile
    private var connectedMac: String? = null

    private var foregroundId = NotificationCenter.ID_IDLE

    /** Last beacon state the Mac was told about, so only changes are sent. */
    private var announcedBeacon: Boolean? = null

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            Log.i(TAG, "Network available, retrying now")
            retryTrigger.trySend(Unit)
        }

        override fun onLost(network: Network) {
            Log.i(TAG, "Network lost, dropping the connection")
            connection?.close()
        }
    }

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        notifications = NotificationCenter(this)
        discovery = Discovery(this)
        connectivity = getSystemService(ConnectivityManager::class.java)
        ringer = Ringer(this)
        outbox = Outbox(this)
        incomingFiles = IncomingFiles(this)
        beacon = PresenceAdvertiser(this)
        announcedBeacon = beaconWanted
        scope.launch { outbox.sweepIncomplete() }

        notifications.createChannels()
        showIdle()

        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        runCatching { connectivity.registerNetworkCallback(request, networkCallback) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // The beacon is independent of the clipboard sync, so it is settled
        // before anything else and survives a "stop the sync" request.
        updateBeacon()

        when (intent?.action) {
            ACTION_STOP -> {
                Log.i(TAG, "Stop requested")
                prefs.syncEnabled = false
                stopWithGoodbye()
                return START_NOT_STICKY
            }
            ACTION_RECONNECT -> {
                connection?.close()
                retryTrigger.trySend(Unit)
            }
            ACTION_SEND_CLIPBOARD -> sendClipboardToMac(intent.getStringExtra(EXTRA_TEXT).orEmpty())
            ACTION_SEND_FILES -> {
                // The files are already staged in the cache by ShareActivity.
                retryTrigger.trySend(Unit)
                drainOutbox()
            }
            ACTION_LOCK_MAC -> lockTheMac()
            ACTION_QUERY_STATUS -> broadcastStatus()
            ACTION_SILENCE -> silenceRing()
        }

        // A shared file keeps the service connecting even with clipboard sync off:
        // the user asked for that transfer explicitly. The beacon on its own
        // never opens a connection - it needs no Mac on the network.
        if (prefs.syncEnabled || hasQueuedFiles()) startConnectionLoop() else showIdle()
        announceBeaconIfChanged()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        beacon.stop()
        ringer.stop()
        runCatching { connectivity.unregisterNetworkCallback(networkCallback) }
        connection?.close()
        scope.cancel()
        super.onDestroy()
    }

    // region Connection loop

    private fun startConnectionLoop() {
        if (loopJob?.isActive == true) return
        loopJob = scope.launch {
            var failures = 0
            while (isActive) {
                if (!prefs.syncEnabled && !hasQueuedFiles()) break
                val connected = attemptConnection()
                failures = if (connected) 0 else failures + 1
                val wait = BACKOFF_MS[minOf(failures, BACKOFF_MS.lastIndex)]
                Log.d(TAG, "Next attempt in ${wait / 1000}s")
                withTimeoutOrNull(wait) { retryTrigger.receive() }
            }
        }
    }

    /** Returns true when the session was actually established. */
    private suspend fun attemptConnection(): Boolean {
        val pairingCode = prefs.pairingCode
        if (pairingCode.isBlank()) {
            broadcastStatus(message = getString(R.string.status_missing_code))
            return false
        }

        val port = prefs.port
        val manualHost = prefs.manualHost
        val endpoint = if (manualHost.isNotEmpty()) {
            Discovery.Endpoint(manualHost, port, null)
        } else {
            discovery.findMac(DISCOVERY_TIMEOUT_MS)?.copy(port = port)
        }
        if (endpoint == null) {
            Log.d(TAG, "No Mac found on this network")
            broadcastStatus()
            return false
        }

        Log.i(TAG, "Connecting to ${endpoint.host}:${endpoint.port}")
        var established = false
        val socket = Socket()
        try {
            socket.connect(InetSocketAddress(endpoint.host, endpoint.port), CONNECT_TIMEOUT_MS)
            socket.soTimeout = Wire.RECEIVE_TIMEOUT_MS.toInt()
            socket.keepAlive = true
            socket.tcpNoDelay = true

            val peer = PeerConnection(
                socket = socket,
                pairingCode = pairingCode,
                deviceName = deviceName(),
                deviceId = prefs.deviceId,
                beaconEnabled = beaconWanted,
            )
            peer.fileSink = incomingFiles
            connection = peer

            val heartbeat = scope.launch {
                while (isActive) {
                    delay(HEARTBEAT_CHECK_MS)
                    runCatching { peer.sendHeartbeatIfIdle() }
                }
            }
            try {
                peer.runLoop(listener)
                established = peer.isAuthenticated
            } finally {
                heartbeat.cancel()
            }
        } catch (error: Exception) {
            Log.i(TAG, "Connection to ${endpoint.host} failed: ${error.message}")
        } finally {
            runCatching { socket.close() }
            connection = null
            connectedMac = null
            pendingAcks.values.forEach { it.complete(FileVerdict(ok = false, detail = null, delivered = false)) }
            pendingAcks.clear()
            // A file that was still arriving is thrown away, so Download never
            // keeps a half written item; the Mac queues it again.
            incomingFiles.abort()
            notifications.cancel(NotificationCenter.ID_TRANSFER)
            notifications.cancel(NotificationCenter.ID_INCOMING)
            showIdle()
        }
        return established
    }

    private val listener = object : PeerConnection.Listener {
        override fun onAuthenticated(macName: String) {
            Log.i(TAG, "Authenticated with $macName")
            connectedMac = macName
            showConnected(macName)
            drainOutbox()
        }

        override fun onClipboard(text: String) {
            applyClipboard(text)
        }

        override fun onClipboardRequested() {
            openBridgeToRead()
        }

        override fun onPing(macName: String) {
            // A ping is a "find my phone", so it rings instead of blipping once.
            notifications.showPing(macName)
            ringer.start()
        }

        override fun onFileAck(fileId: String, ok: Boolean, path: String?, reason: String?) {
            Log.i(TAG, "File $fileId ${if (ok) "saved as $path" else "refused: $reason"}")
            pendingAcks.remove(fileId)?.complete(FileVerdict(ok = ok, detail = reason ?: path))
        }

        override fun onIncomingProgress(name: String, received: Long, total: Long) {
            notifications.showIncomingTransfer(name, received, total)
        }

        override fun onFileReceived(name: String, saved: IncomingFiles.Saved) {
            notifications.cancel(NotificationCenter.ID_INCOMING)
            notifications.showFileReceived(saved)
        }

        override fun onFileRefused(name: String, reason: String) {
            notifications.cancel(NotificationCenter.ID_INCOMING)
            notifications.showFileResult(name, ok = false, detail = reason)
        }
    }

    // endregion

    // region Files

    /** What the Mac said about one file; [delivered] is false when nothing came back. */
    private data class FileVerdict(val ok: Boolean, val detail: String?, val delivered: Boolean = true)

    private fun hasQueuedFiles(): Boolean = !outbox.isEmpty()

    /**
     * Sends the queued files one by one. Only one drain runs at a time; it stops
     * as soon as the queue is empty or the connection is gone, and whatever is
     * left stays in the cache for the next connection.
     */
    private fun drainOutbox() {
        if (drainJob?.isActive == true) return
        drainJob = scope.launch {
            while (isActive) {
                val peer = connection?.takeIf { it.isAuthenticated } ?: break
                val item = outbox.items().firstOrNull() ?: break
                if (!sendFile(peer, item)) break
            }
            notifications.cancel(NotificationCenter.ID_TRANSFER)
            // Without clipboard sync the connection only existed for the queue.
            if (!prefs.syncEnabled && outbox.isEmpty()) {
                Log.i(TAG, "Queue is empty and sync is off, disconnecting")
                connection?.close()
            }
        }
    }

    /** Returns false when the drain should stop, for example a dead connection. */
    private suspend fun sendFile(peer: PeerConnection, item: Outbox.Item): Boolean {
        val fileId = UUID.randomUUID().toString()
        val ack = CompletableDeferred<FileVerdict>()
        pendingAcks[fileId] = ack
        val queued = (outbox.items().size - 1).coerceAtLeast(0)
        var lastShownAt = 0L

        try {
            notifications.showTransfer(item.name, 0, item.size, queued)
            peer.sendFile(item, fileId) { sent, total ->
                val now = System.currentTimeMillis()
                if (now - lastShownAt >= PROGRESS_INTERVAL_MS || sent == total) {
                    lastShownAt = now
                    notifications.showTransfer(item.name, sent, total, queued)
                }
            }
        } catch (error: Exception) {
            pendingAcks.remove(fileId)
            Log.w(TAG, "Sending ${item.name} failed, it stays in the queue", error)
            return false
        }

        val verdict = withTimeoutOrNull(ACK_TIMEOUT_MS) { ack.await() }
        pendingAcks.remove(fileId)

        if (verdict == null || !verdict.delivered) {
            val tries = attempts.merge(item.file.path, 1, Int::plus) ?: 1
            if (tries >= MAX_ATTEMPTS) {
                Log.w(TAG, "Giving up on ${item.name} after $tries attempts")
                attempts.remove(item.file.path)
                outbox.remove(item)
                notifications.showFileResult(item.name, ok = false, detail = getString(R.string.file_error_no_answer))
                return true
            }
            Log.i(TAG, "No answer for ${item.name}, keeping it queued (attempt $tries)")
            return false
        }

        attempts.remove(item.file.path)
        // Either it landed on the Mac or the Mac refused it; both are final, so
        // the staged copy goes away and the queue keeps moving.
        outbox.remove(item)
        notifications.showFileResult(item.name, verdict.ok, verdict.detail)
        return true
    }

    // endregion

    // region Presence beacon

    /**
     * Whether this phone should be broadcasting at all. The beacon rides along
     * with the clipboard sync: switching the sync off switches the radio off too.
     */
    private val beaconWanted: Boolean
        get() = prefs.beaconEnabled && prefs.syncEnabled

    /** Starts or stops the radio to match the switches. */
    private fun updateBeacon() {
        if (beaconWanted) beacon.start(prefs.pairingCode) else beacon.stop()
    }

    /**
     * Tells the Mac that the switch moved. That message matters: a beacon which
     * simply disappears looks exactly like the user walking away, and the Mac
     * would lock the screen of someone sitting right in front of it.
     *
     * Called at the end of the command, after any reconnect has already dropped
     * the session: sending into a socket that the same command is closing would
     * only ever fail, and the handshake of the next connection carries the state
     * anyway.
     */
    private fun announceBeaconIfChanged() {
        val enabled = beaconWanted
        if (announcedBeacon == enabled) return
        announcedBeacon = enabled

        val peer = connection?.takeIf { it.isAuthenticated }
        if (peer == null) {
            Log.i(TAG, "Presence beacon ${if (enabled) "on" else "off"}, no Mac connected to tell")
            return
        }
        scope.launch {
            runCatching { peer.sendPresence(enabled) }
                .onFailure { Log.w(TAG, "Could not tell the Mac about the beacon: ${it.message}") }
        }
    }

    /**
     * Sends the manual lock. Deliberately unrelated to [Prefs.beaconEnabled]: the
     * user pressed a button, which is a clearer signal than any measurement.
     */
    private fun lockTheMac() {
        val peer = connection?.takeIf { it.isAuthenticated }
        if (peer == null) {
            Log.i(TAG, "No Mac connected, cannot lock it")
            broadcastStatus(message = getString(R.string.status_lock_no_mac))
            return
        }
        // onStartCommand runs on the main thread, socket writes must not.
        scope.launch {
            runCatching { peer.sendLockRequest() }
                .onSuccess { Log.i(TAG, "Asked the Mac to lock its screen") }
                .onFailure { Log.w(TAG, "Could not ask the Mac to lock", it) }
        }
    }

    // endregion

    // region Clipboard

    /**
     * Hands the text to the transparent window, which is the only way to write
     * the clipboard on Android 10 and newer. Starting an activity from the
     * background needs the "display over other apps" permission; without it the
     * user gets a tappable notification instead.
     */
    private fun applyClipboard(text: String) {
        if (Settings.canDrawOverlays(this)) {
            runCatching { startActivity(ClipboardBridgeActivity.writeIntent(this, text)) }
                .onFailure {
                    Log.w(TAG, "Could not open the clipboard window", it)
                    notifications.showPendingClipboard(connectedMac ?: "Mac", text)
                }
        } else {
            Log.w(TAG, "Overlay permission missing, falling back to a notification")
            notifications.showPendingClipboard(connectedMac ?: "Mac", text)
        }
    }

    private fun openBridgeToRead() {
        if (!Settings.canDrawOverlays(this)) return
        runCatching { startActivity(ClipboardBridgeActivity.readIntent(this)) }
    }

    private fun sendClipboardToMac(text: String) {
        if (text.isEmpty()) return
        if (text.toByteArray(Charsets.UTF_8).size > Wire.MAX_CLIPBOARD_BYTES) {
            Log.i(TAG, "Clipboard is larger than ${Wire.MAX_CLIPBOARD_BYTES} bytes, not sending it")
            return
        }
        val peer = connection
        if (peer == null || !peer.isAuthenticated) {
            Log.i(TAG, "No Mac connected, clipboard not sent")
            return
        }
        // onStartCommand runs on the main thread, socket writes must not.
        scope.launch {
            runCatching { peer.sendClipboard(text) }
                .onFailure { Log.w(TAG, "Sending the clipboard failed", it) }
        }
    }

    // endregion

    // region Notifications and status

    private fun showConnected(macName: String) {
        val notification = notifications.activeNotification(macName)
        startForegroundCompat(NotificationCenter.ID_ACTIVE, notification)
        notifications.cancel(NotificationCenter.ID_IDLE)
        foregroundId = NotificationCenter.ID_ACTIVE
        broadcastStatus()
    }

    private fun showIdle() {
        val notification = notifications.idleNotification()
        startForegroundCompat(NotificationCenter.ID_IDLE, notification)
        notifications.cancel(NotificationCenter.ID_ACTIVE)
        foregroundId = NotificationCenter.ID_IDLE
        broadcastStatus()
    }

    private fun startForegroundCompat(id: Int, notification: android.app.Notification) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(id, notification)
            }
        } catch (error: Exception) {
            Log.e(TAG, "Could not go foreground", error)
        }
    }

    /**
     * Shuts down, but not before the Mac has been told that the beacon is going
     * away. Skipping that message would leave the Mac watching for a beacon that
     * is never coming back, which is indistinguishable from the user walking
     * off - and it would lock the screen of someone sitting right there.
     *
     * The write cannot happen on this thread, so the teardown waits for it, with
     * a short timeout in case the socket is already dead.
     */
    private fun stopWithGoodbye() {
        val peer = connection?.takeIf { it.isAuthenticated }
        if (peer == null || announcedBeacon != true) {
            stopEverything()
            return
        }
        announcedBeacon = false
        scope.launch {
            withTimeoutOrNull(GOODBYE_TIMEOUT_MS) {
                runCatching { peer.sendPresence(false) }
                    .onSuccess { Log.i(TAG, "Told the Mac the beacon is going away") }
                    .onFailure { Log.w(TAG, "Could not tell the Mac: ${it.message}") }
            }
            withContext(Dispatchers.Main) { stopEverything() }
        }
    }

    private fun stopEverything() {
        beacon.stop()
        ringer.stop()
        drainJob?.cancel()
        drainJob = null
        loopJob?.cancel()
        loopJob = null
        connection?.close()
        connection = null
        connectedMac = null
        broadcastStatus()
        stopForeground(STOP_FOREGROUND_REMOVE)
        notifications.cancel(NotificationCenter.ID_IDLE)
        notifications.cancel(NotificationCenter.ID_ACTIVE)
        notifications.cancel(NotificationCenter.ID_PING)
        notifications.cancel(NotificationCenter.ID_TRANSFER)
        notifications.cancel(NotificationCenter.ID_INCOMING)
        stopSelf()
    }

    private fun broadcastStatus(message: String? = null) {
        val intent = Intent(BROADCAST_STATUS)
            .setPackage(packageName)
            .putExtra(EXTRA_CONNECTED, connectedMac != null)
            .putExtra(EXTRA_DEVICE, connectedMac)
            .putExtra(EXTRA_MESSAGE, message)
        sendBroadcast(intent)
    }

    private fun silenceRing() {
        Log.i(TAG, "Ring silenced")
        ringer.stop()
        notifications.cancel(NotificationCenter.ID_PING)
    }

    private fun deviceName(): String {
        val manufacturer = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
        return if (Build.MODEL.startsWith(manufacturer, ignoreCase = true)) {
            Build.MODEL
        } else {
            "$manufacturer ${Build.MODEL}"
        }
    }

    // endregion

    companion object {
        private const val TAG = Prefs.TAG

        const val ACTION_START = "pl.wojas.macdroidsync.START"
        const val ACTION_STOP = "pl.wojas.macdroidsync.STOP"
        const val ACTION_RECONNECT = "pl.wojas.macdroidsync.RECONNECT"
        const val ACTION_SEND_CLIPBOARD = "pl.wojas.macdroidsync.SEND_CLIPBOARD"
        const val ACTION_SEND_FILES = "pl.wojas.macdroidsync.SEND_FILES"
        const val ACTION_QUERY_STATUS = "pl.wojas.macdroidsync.QUERY_STATUS"
        const val ACTION_SILENCE = "pl.wojas.macdroidsync.SILENCE"
        const val ACTION_LOCK_MAC = "pl.wojas.macdroidsync.LOCK_MAC"

        const val BROADCAST_STATUS = "pl.wojas.macdroidsync.STATUS"
        const val EXTRA_TEXT = "text"
        const val EXTRA_CONNECTED = "connected"
        const val EXTRA_DEVICE = "device"
        const val EXTRA_MESSAGE = "message"

        private const val CONNECT_TIMEOUT_MS = 5_000
        private const val DISCOVERY_TIMEOUT_MS = 6_000L
        private const val HEARTBEAT_CHECK_MS = 5_000L
        private const val ACK_TIMEOUT_MS = 60_000L
        private const val PROGRESS_INTERVAL_MS = 500L
        private const val GOODBYE_TIMEOUT_MS = 2_000L
        private const val MAX_ATTEMPTS = 3
        private val BACKOFF_MS = longArrayOf(1_000, 2_000, 5_000, 10_000, 30_000)

        fun start(context: Context, action: String = ACTION_START) {
            val intent = Intent(context, SyncService::class.java).setAction(action)
            runCatching { context.startForegroundService(intent) }
                .onFailure { Log.w(TAG, "Could not start the service", it) }
        }

        fun stop(context: Context) = start(context, ACTION_STOP)
    }
}

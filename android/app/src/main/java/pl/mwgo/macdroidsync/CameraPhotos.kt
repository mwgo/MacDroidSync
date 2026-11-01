package pl.mwgo.macdroidsync

import android.content.ContentValues
import android.content.Context
import android.net.ConnectivityManager
import android.net.MacAddress
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * The pictures on the Fujifilm camera: lists them over the camera's own Wi-Fi,
 * imports those never imported before into Pictures/<camera>, and fetches one
 * on request for the viewer.
 *
 * Joining the camera's Wi-Fi takes its link over Bluetooth to start the access
 * point first. The session stays open while the viewer is open or a transfer
 * runs, and ends soon after, which is what returns the camera to normal.
 */
object CameraPhotos {

    /** A picture on the camera, in this phone's gallery, or both. */
    data class Photo(val key: String, val handle: Int?, val filename: String, val taken: Long, val uri: Uri?)

    sealed class State {
        object Idle : State()
        data class Busy(val step: Int) : State()
        data class Ready(val photos: List<Photo>) : State()
        data class Failed(val reason: String) : State()
    }

    var state: State = State.Idle
        private set

    /** Called on the main thread whenever [state] changes or an import progresses. */
    var onChange: (() -> Unit)? = null

    var importing: Pair<Int, Int>? = null
        private set

    /** Whether the camera's Wi-Fi is in use, which keeps the camera counted as on. */
    val active: Boolean
        get() = importing != null || state is State.Busy || state is State.Ready

    private val main = Handler(Looper.getMainLooper())
    /**
     * One PTP transaction at a time, on this thread. The picture on screen goes
     * before the previews of the grid around it.
     */
    private val worker = java.util.concurrent.ThreadPoolExecutor(
        1, 1, 0, java.util.concurrent.TimeUnit.SECONDS, java.util.concurrent.PriorityBlockingQueue(),
    ) { Thread(it, "camera-photos") }
    private val order = java.util.concurrent.atomic.AtomicLong()

    private class Job(val later: Boolean, val number: Long, val block: () -> Unit) : Runnable, Comparable<Job> {
        override fun run() = block()
        override fun compareTo(other: Job): Int =
            compareValuesBy(this, other, { it.later }, { if (it.later) -it.number else it.number })
    }

    /** Previews last and newest first: the ones just scrolled to matter most. */
    private fun onWorker(later: Boolean = false, block: () -> Unit) {
        worker.execute(Job(later, order.incrementAndGet()) {
            try {
                block()
            } catch (error: java.net.SocketTimeoutException) {
                // A reply that never came leaves the stream out of step: start over next time.
                Log.w(Prefs.TAG, "The camera stopped answering", error)
                main.post { fail(appContext?.getString(R.string.photos_camera_silent) ?: "") }
            }
        })
    }
    private var ptp: FujiPtp? = null
    private var network: Network? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var appContext: Context? = null
    private var cameraPhotos: List<FujiPtp.ObjectInfo> = emptyList()
    private var waiting = mutableListOf<() -> Unit>()
    private val rest = Runnable { close() }

    // region Session

    /** Opens the session if needed, then runs [then] on the main thread. */
    fun connect(context: Context, then: () -> Unit = {}) {
        val app = context.applicationContext
        appContext = app
        main.removeCallbacks(rest)
        when (state) {
            is State.Ready -> {
                then()
                return
            }
            is State.Busy -> {
                waiting.add(then)
                return
            }
            else -> Unit
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            fail(app.getString(R.string.photos_needs_android_10))
            return
        }
        val link = CameraLinkService.instance?.takeIf { it.ready }
        val saved = Prefs(app).cameraWifi.split('\n').takeIf { it.size == 3 }
            ?.let { (ssid, passphrase, bssid) -> CameraLinkService.Wifi(ssid, passphrase, bssid) }
        if (link == null && saved == null) {
            fail(app.getString(R.string.photos_camera_off))
            return
        }
        waiting.add(then)
        if (link == null) {
            // Without Bluetooth the camera may still be waiting on its Wi-Fi, as after a session cut short.
            Log.i(Prefs.TAG, "No Bluetooth link, trying the camera's Wi-Fi as it was last")
            join(app, saved!!, SAVED_JOIN_TIMEOUT_MS)
            return
        }
        update(State.Busy(R.string.photos_step_wifi))
        link.startWifi { wifi ->
            if (wifi == null) {
                fail(app.getString(R.string.photos_wifi_failed))
            } else {
                Prefs(app).cameraWifi = "${wifi.ssid}\n${wifi.passphrase}\n${wifi.bssid}"
                join(app, wifi)
            }
        }
    }

    private fun join(context: Context, wifi: CameraLinkService.Wifi, timeoutMs: Int = JOIN_TIMEOUT_MS) {
        update(State.Busy(R.string.photos_step_join))
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(wifi.ssid)
            .setWpa2Passphrase(wifi.passphrase)
            .apply { runCatching { setBssid(MacAddress.fromString(wifi.bssid)) } }
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(available: Network) {
                Log.i(Prefs.TAG, "Joined the camera's Wi-Fi")
                network = available
                onWorker { open(context, available) }
            }

            override fun onUnavailable() {
                main.post { fail(context.getString(R.string.photos_join_failed)) }
            }

            override fun onLost(lost: Network) {
                if (lost == network) main.post { close() }
            }
        }
        networkCallback = callback
        runCatching { manager.requestNetwork(request, callback, timeoutMs) }.onFailure {
            Log.w(Prefs.TAG, "Could not ask for the camera's Wi-Fi", it)
            networkCallback = null
            fail(context.getString(R.string.photos_join_failed))
        }
    }

    /** On the worker: the PTP session, set up as XApp does for viewing pictures, then the list. */
    private fun open(context: Context, available: Network) {
        val session = try {
            connectWithRetries(context, available)
        } catch (error: Exception) {
            Log.w(Prefs.TAG, "Camera session failed", error)
            main.post { fail(context.getString(R.string.photos_session_failed, error.message ?: "")) }
            return
        }
        ptp = session
        session.trace = { Log.d(Prefs.TAG, "PTP $it") }
        try {
            Log.i(Prefs.TAG, "Camera events ${session.events()}")
            // The camera may ask on its screen whether to accept this phone, and
            // keeps the next answer until someone does.
            main.post { update(State.Busy(R.string.photos_step_accept)) }
            session.timeoutMs = ACCEPT_TIMEOUT_MS
            session.setProperty16(FujiPtp.DPC_CLIENT_STATE, FujiPtp.CLIENT_IMAGE_VIEW_XAPP)
            Log.i(Prefs.TAG, "Camera events ${session.events()}")
            val version = session.getProperty(FujiPtp.DPC_PHOTO_VIEW_VERSION)
            Log.i(Prefs.TAG, "Camera photo view version ${version.joinToString(" ") { "%02x".format(it) }}")
            session.setProperty(FujiPtp.DPC_PHOTO_VIEW_VERSION, version)
            main.post { update(State.Busy(R.string.photos_step_list)) }
            session.setProperty16(FujiPtp.DPC_COMPRESS, 0)
            session.setProperty16(FujiPtp.DPC_CORRECT_SIZE, 0)
            Log.i(Prefs.TAG, "Camera events ${session.events()}")
            session.timeoutMs = REPLY_TIMEOUT_MS
            list(session)
            deleteTrashed(context, session)
            remember(context)
        } catch (error: Exception) {
            Log.w(Prefs.TAG, "Listing the camera's pictures failed", error)
            main.post { fail(context.getString(R.string.photos_session_failed, error.message ?: "")) }
            return
        }
        main.post { ready(context) }
    }

    private fun connectWithRetries(context: Context, available: Network): FujiPtp {
        val name = FujifilmCamera.phoneName(context)
        val deadline = System.currentTimeMillis() + CONNECT_WINDOW_MS
        var last: Exception? = null
        while (System.currentTimeMillis() < deadline) {
            try {
                return FujiPtp.open(available.socketFactory, name)
            } catch (error: Exception) {
                last = error
                Thread.sleep(if (error is FujiPtp.PtpException) 500 else 1_000)
            }
        }
        throw last ?: IllegalStateException("no connection")
    }

    private fun list(session: FujiPtp) {
        // XApp's way into the gallery, as Fudge replays it; the camera builds the
        // list the count and handles come from only after these.
        session.transact(FujiPtp.OC_FUJI_EXTENSION_INFO, FujiPtp.LATEST)
        session.transact(FujiPtp.OC_FUJI_EXTENSION_THUMB, FujiPtp.LATEST)
        session.transact(FujiPtp.OC_FUJI_IMPORT_FOLDERS)
        session.transact(FujiPtp.OC_GET_DEVICE_PROP_VALUE, FujiPtp.DPC_UNKNOWN_D22B)
        session.transact(FujiPtp.OC_FUJI_IMPORT_DATES, 0, 30_000)
        val count = session.getPropertyInt(FujiPtp.DPC_OBJECT_COUNT)
        val raw = session.getProperty(FujiPtp.DPC_OBJECT_HANDLES)
        var handles = FujiPtp.parseHandles(raw)
        Log.i(Prefs.TAG, "Camera has $count pictures, handle list ${raw.size} bytes, ${handles.size} handles")
        if (handles.isEmpty() && count > 0) handles = (1..count).toList()
        cameraPhotos = handles.mapNotNull { handle ->
            runCatching { session.objectInfo(handle) }
                .onFailure { Log.w(Prefs.TAG, "No info for picture $handle: ${it.message}") }
                .getOrNull()
        }.filter { it.isJpeg }
        Log.i(Prefs.TAG, "Camera JPEGs: ${cameraPhotos.size}, newest ${cameraPhotos.maxByOrNull { it.captureDate }}")
    }

    /**
     * The camera's list as it was, so the next look shows what is still only
     * on the camera at once, before any session: name and date, with the
     * previews already cached.
     */
    private fun remember(context: Context) {
        val address = Prefs(context).cameraAddress
        val json = JSONObject()
        cameraPhotos.forEach { info ->
            json.put(key(address, info), JSONObject().put("name", info.filename).put("taken", taken(info.captureDate)))
        }
        runCatching { File(context.filesDir, LISTING_FILE).writeText(json.toString()) }
    }

    private fun remembered(context: Context): List<Photo> {
        val json = runCatching { JSONObject(File(context.filesDir, LISTING_FILE).readText()) }.getOrNull() ?: return emptyList()
        return json.keys().asSequence().map { key ->
            val entry = json.getJSONObject(key)
            Photo(key, null, entry.optString("name"), entry.optLong("taken"), null)
        }.toList()
    }

    /** Whether a picture on the camera can be fetched now, without waiting on a camera that is off. */
    val reachable: Boolean
        get() = state is State.Ready || state is State.Busy || CameraLinkService.instance?.ready == true

    /** What was thrown away while the camera was off goes off its card now. */
    private fun deleteTrashed(context: Context, session: FujiPtp) {
        val history = History(context)
        val trashed = history.trashed()
        if (trashed.isEmpty()) return
        val address = Prefs(context).cameraAddress
        val gone = cameraPhotos.filter { key(address, it) in trashed }
        gone.forEach { info ->
            val code = runCatching { session.transact(FujiPtp.OC_DELETE_OBJECT, info.handle).code }.getOrNull()
            Log.i(Prefs.TAG, "Deleted ${info.filename} on the camera, thrown away before: ${code?.let { "0x%04X".format(it) }}")
            if (code == FujiPtp.RC_OK) history.remove(key(address, info))
        }
        cameraPhotos = cameraPhotos - gone.toSet()
    }

    private fun ready(context: Context) {
        update(State.Ready(photos(context)))
        val run = waiting
        waiting = mutableListOf()
        run.forEach { it() }
        scheduleRest()
    }

    private fun fail(reason: String) {
        Log.w(Prefs.TAG, "Camera pictures: $reason")
        waiting.clear()
        release()
        update(State.Failed(reason))
        if (downloading) finishImport(0)
    }

    /** A failure is old news once the camera is back over Bluetooth. */
    fun forgetFailure() {
        if (state is State.Failed) update(State.Idle)
    }

    fun close() {
        if (state is State.Idle) return
        waiting.clear()
        release()
        update(State.Idle)
    }

    private val stalled = Runnable { fail(appContext?.getString(R.string.photos_wifi_failed) ?: "") }

    private fun release() {
        main.removeCallbacks(rest)
        val session = ptp
        ptp = null
        onWorker { session?.close() }
        networkCallback?.let { callback ->
            runCatching { appContext?.getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(callback) }
        }
        networkCallback = null
        network = null
        cameraPhotos = emptyList()
    }

    /** Set while the viewer is open: the camera stays on its Wi-Fi for the next picture. */
    var held = false
        set(value) {
            field = value
            if (state is State.Ready) scheduleRest()
        }

    /** The camera stays black on its Wi-Fi until the session ends, so it ends soon after use. */
    private fun scheduleRest() {
        main.removeCallbacks(rest)
        if (importing == null && !held) main.postDelayed(rest, REST_MS)
    }

    private fun update(new: State) {
        state = new
        // No step of getting connected takes this long; a silent camera is not waited for forever.
        main.removeCallbacks(stalled)
        if (new is State.Busy) main.postDelayed(stalled, CONNECT_LIMIT_MS)
        changed()
        // Over, the camera counts as on only for what Bluetooth says about it.
        if (!active) appContext?.let { FujifilmCamera.refresh(it) }
    }

    private fun changed() {
        onChange?.invoke()
        CameraLinkService.instance?.photosChanged()
    }

    // endregion

    // region Pictures

    /** The camera's pictures with what was imported before, newest first. */
    fun photos(context: Context): List<Photo> {
        val store = History(context)
        val address = Prefs(context).cameraAddress
        val listed = if (state is State.Ready) {
            cameraPhotos.map { info ->
                val key = key(address, info)
                Photo(key, info.handle, info.filename, taken(info.captureDate), store.uri(key))
            }
        } else {
            remembered(context).map { it.copy(uri = store.uri(it.key)) }
        }
        val onCamera = listed
            .filter { it.key !in store.trashed() }
        val keys = onCamera.map { it.key }.toSet()
        val onlyHere = store.all().filterKeys { it !in keys }.map { (key, entry) ->
            Photo(key, null, entry.optString("name"), entry.optLong("taken"), Uri.parse(entry.optString("uri")))
        }
        return (onCamera + onlyHere).sortedByDescending { it.taken }
    }

    /** Imports every picture on the camera that was never imported, newest first. */
    fun importNew(context: Context, done: (imported: Int, stopped: Boolean) -> Unit) {
        val app = context.applicationContext
        stopping = false
        downloading = true
        importDone = done
        connect(app) {
            val fresh = photos(app).filter { it.handle != null && it.uri == null }
            if (fresh.isEmpty() || stopping) {
                finishImport(0)
                scheduleRest()
                return@connect
            }
            importing = 0 to fresh.size
            main.removeCallbacks(rest)
            changed()
            var imported = 0
            fresh.forEachIndexed { index, photo ->
                fetchOnWorker(app, photo, stoppable = true) { uri ->
                    if (uri != null) imported++
                    importing = (index + 1) to fresh.size
                    if (index == fresh.lastIndex) {
                        importing = null
                        update(State.Ready(photos(app)))
                        scheduleRest()
                        finishImport(imported)
                    } else {
                        changed()
                    }
                }
            }
        }
    }

    /**
     * Ends an import at the next 1 MiB chunk; the picture being read then is
     * dropped, those finished stay. The camera keeps the session in step,
     * since no transfer is cut in the middle.
     */
    fun stopImport() {
        if (!downloading) return
        stopping = true
        if (importing == null) {
            // Still starting the camera's Wi-Fi or joining it: nothing to finish, end it all.
            close()
            finishImport(0)
        }
    }

    /** From the tap on Download until the import is over, stopped or failed. */
    var downloading = false
        private set
    private var importDone: ((Int, Boolean) -> Unit)? = null

    private fun finishImport(imported: Int) {
        val done = importDone
        importDone = null
        downloading = false
        importing = null
        changed()
        done?.invoke(imported, stopping)
    }

    @Volatile
    private var stopping = false

    /** The full picture into the gallery, unless it is there already; the result on the main thread. */
    fun fetch(context: Context, photo: Photo, done: (Uri?) -> Unit) {
        if (photo.uri != null) {
            done(photo.uri)
            return
        }
        val app = context.applicationContext
        if (!reachable) {
            done(null)
            return
        }
        connect(app) {
            // Remembered from an earlier session, it gets its handle from this one.
            val current = photo.takeIf { it.handle != null } ?: photos(app).firstOrNull { it.key == photo.key }
                ?: return@connect done(null)
            fetchOnWorker(app, current) { uri ->
                if (importing == null) update(State.Ready(photos(app)))
                scheduleRest()
                done(uri)
            }
        }
    }

    /**
     * Into the phone's trash, from which the gallery can still bring it back,
     * and off the camera's card for good. The camera's copy goes only while the
     * session is open; with the camera off just the phone's is thrown away.
     */
    fun trash(context: Context, photo: Photo) {
        val app = context.applicationContext
        photo.uri?.let { uri ->
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_TRASHED, 1) }
                    app.contentResolver.update(uri, values, null, null)
                } else {
                    app.contentResolver.delete(uri, null, null)
                }
            }.onFailure { Log.w(Prefs.TAG, "Could not trash ${photo.filename}", it) }
        }
        val handle = photo.handle
        // Remembered either way: not imported again, and off the card at the next session.
        History(app).trash(photo.key, photo.filename, photo.taken)
        if (handle != null && state is State.Ready) {
            cameraPhotos = cameraPhotos.filter { it.handle != handle }
            onWorker {
                val answer = runCatching { ptp?.transact(FujiPtp.OC_DELETE_OBJECT, handle)?.code }
                Log.i(Prefs.TAG, "Deleted ${photo.filename} on the camera: ${answer.getOrNull()?.let { "0x%04X".format(it) } ?: answer.exceptionOrNull()}")
                if (answer.getOrNull() == FujiPtp.RC_OK) History(app).remove(photo.key)
            }
            scheduleRest()
        }
        update(if (state is State.Ready) State.Ready(photos(app)) else state)
    }

    /** The camera's small preview, cached, or null; the result on the main thread. */
    fun thumbnail(context: Context, photo: Photo, urgent: Boolean = false, done: (ByteArray?) -> Unit) {
        val file = File(File(context.cacheDir, "camera-thumbs").apply { mkdirs() }, "${photo.key.hashCode()}.jpg")
        if (file.exists()) {
            done(file.readBytes())
            return
        }
        val handle = photo.handle ?: return done(null)
        if (state !is State.Ready) return done(null)
        // The picture on screen's preview goes first; the grid's after everything else.
        onWorker(later = !urgent) {
            val bytes = runCatching { ptp?.let { exifThumbnail(it, handle) } }
                .onFailure { if (it is java.net.SocketTimeoutException) throw it }
                .getOrNull()
            if (bytes != null) runCatching { file.writeBytes(bytes) }
            main.post { done(bytes) }
        }
    }

    /**
     * The preview in the JPEG's own EXIF, read from the head of the file. While
     * the camera serves XApp's gallery, GetThumb gets no answer and Fuji's own
     * thumbnail operation takes only the newest picture.
     */
    private fun exifThumbnail(session: FujiPtp, handle: Int): ByteArray? {
        // As for a download: the camera serves a file only once asked for its info in this mode.
        session.setProperty16(FujiPtp.DPC_COMPRESS, 2)
        try {
            session.objectInfo(handle)
            return FujiPtp.embeddedJpeg(session.partial(handle, 0, THUMBNAIL_HEAD))
        } finally {
            session.setProperty16(FujiPtp.DPC_COMPRESS, 0)
        }
    }

    private fun fetchOnWorker(context: Context, photo: Photo, stoppable: Boolean = false, done: (Uri?) -> Unit) {
        val handle = photo.handle ?: return done(null)
        onWorker {
            val uri = if (stoppable && stopping) null else runCatching { download(context, handle, stoppable) }
                .onFailure {
                    Log.w(Prefs.TAG, "Download of ${photo.filename} failed", it)
                    if (it is java.net.SocketTimeoutException) throw it
                }
                .getOrNull()
            main.post { done(uri) }
        }
    }

    /** On the worker: the original, chunk by chunk, straight into MediaStore. */
    private fun download(context: Context, handle: Int, stoppable: Boolean): Uri {
        val session = ptp ?: throw IllegalStateException("no session")
        session.setProperty16(FujiPtp.DPC_COMPRESS, 2)
        try {
            val info = session.objectInfo(handle)
            val prefs = Prefs(context)
            val taken = taken(info.captureDate)
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, info.filename)
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                put(MediaStore.Images.Media.RELATIVE_PATH, FujifilmCamera.picturesFolder(context))
                put(MediaStore.Images.Media.IS_PENDING, 1)
                if (taken > 0) put(MediaStore.Images.Media.DATE_TAKEN, taken)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)
                ?: throw IllegalStateException("MediaStore refused ${info.filename}")
            try {
                resolver.openOutputStream(uri)!!.use { out ->
                    var offset = 0L
                    while (true) {
                        if (stoppable && stopping) throw java.util.concurrent.CancellationException("stopped")
                        val chunk = session.partial(handle, offset, FujiPtp.CHUNK)
                        out.write(chunk)
                        offset += chunk.size
                        // The size in the object info is not to be trusted; a short chunk is the end.
                        if (chunk.size < FujiPtp.CHUNK) break
                    }
                    Log.i(Prefs.TAG, "Imported ${info.filename}, $offset bytes")
                }
                resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
            } catch (error: Exception) {
                resolver.delete(uri, null, null)
                throw error
            }
            History(context).add(key(prefs.cameraAddress, info), uri, info.filename, taken)
            return uri
        } finally {
            runCatching { session.setProperty16(FujiPtp.DPC_COMPRESS, 0) }
        }
    }

    /** What makes a picture the same one again, as XApp keys it: date and file name, per camera. */
    private fun key(address: String, info: FujiPtp.ObjectInfo) = "$address|${info.captureDate}|${info.filename}"

    /** "20261101T105400" in the camera's local time. */
    internal fun taken(captureDate: String): Long =
        runCatching { SimpleDateFormat("yyyyMMdd'T'HHmmss", Locale.US).parse(captureDate.take(15))!!.time }
            .getOrDefault(0L)

    /** What was imported, and where it went, so nothing is imported twice. */
    private class History(context: Context) {
        private val file = File(context.filesDir, "camera-photos.json")
        private val json = runCatching { JSONObject(file.readText()) }.getOrDefault(JSONObject())

        fun uri(key: String): Uri? =
            json.optJSONObject(key)?.takeUnless { it.optBoolean("trashed") }?.optString("uri")?.let(Uri::parse)

        fun all(): Map<String, JSONObject> = json.keys().asSequence().associateWith { json.getJSONObject(it) }
            .filterValues { !it.optBoolean("trashed") }

        fun trashed(): Set<String> = json.keys().asSequence().filter { json.getJSONObject(it).optBoolean("trashed") }.toSet()

        fun trash(key: String, name: String, taken: Long) {
            json.put(key, JSONObject().put("trashed", true).put("name", name).put("taken", taken))
            synchronized(CameraPhotos) { file.writeText(json.toString()) }
        }

        fun remove(key: String) {
            if (json.remove(key) != null) synchronized(CameraPhotos) { file.writeText(json.toString()) }
        }

        fun add(key: String, uri: Uri, name: String, taken: Long) {
            json.put(key, JSONObject().put("uri", uri.toString()).put("name", name).put("taken", taken))
            synchronized(CameraPhotos) { file.writeText(json.toString()) }
        }
    }

    // endregion

    private const val JOIN_TIMEOUT_MS = 60_000
    private const val SAVED_JOIN_TIMEOUT_MS = 60_000
    private const val CONNECT_WINDOW_MS = 30_000L
    private const val REST_MS = 10_000L
    private const val LISTING_FILE = "camera-listing.json"
    private const val THUMBNAIL_HEAD = 128 * 1024
    private const val CONNECT_LIMIT_MS = 90_000L
    private const val ACCEPT_TIMEOUT_MS = 60_000
    private const val REPLY_TIMEOUT_MS = 15_000
}

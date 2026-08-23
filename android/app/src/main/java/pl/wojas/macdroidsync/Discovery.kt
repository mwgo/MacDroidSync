package pl.wojas.macdroidsync

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.util.Log
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume

/** Finds the Mac on the local network through Bonjour (`_macdroidsync._tcp`). */
class Discovery(context: Context) {

    data class Endpoint(val host: String, val port: Int, val name: String?)

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifiManager = context.applicationContext.getSystemService(WifiManager::class.java)

    /** Returns the first Mac that answers, or null when nothing was found in time. */
    suspend fun findMac(timeoutMs: Long): Endpoint? {
        // Some devices drop multicast packets while dozing unless the lock is held.
        val multicastLock = runCatching {
            wifiManager?.createMulticastLock(LOCK_TAG)?.apply {
                setReferenceCounted(true)
                acquire()
            }
        }.getOrNull()
        try {
            return browse(timeoutMs)
        } finally {
            runCatching { multicastLock?.takeIf { it.isHeld }?.release() }
        }
    }

    private suspend fun browse(timeoutMs: Long): Endpoint? = withTimeoutOrNull(timeoutMs) {
        suspendCancellableCoroutine { continuation ->
            val resumed = AtomicBoolean(false)
            var discoveryListener: NsdManager.DiscoveryListener? = null

            fun finish(endpoint: Endpoint?) {
                if (!resumed.compareAndSet(false, true)) return
                discoveryListener?.let { runCatching { nsdManager.stopServiceDiscovery(it) } }
                continuation.resume(endpoint)
            }

            @Suppress("DEPRECATION")
            val resolveListener = object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    Log.w(TAG, "Resolve failed for ${serviceInfo.serviceName}: $errorCode")
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    val host = serviceInfo.host?.hostAddress ?: return
                    Log.i(TAG, "Discovered ${serviceInfo.serviceName} at $host:${serviceInfo.port}")
                    finish(Endpoint(host, serviceInfo.port, serviceInfo.serviceName))
                }
            }

            val listener = object : NsdManager.DiscoveryListener {
                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                    Log.w(TAG, "Discovery could not start: $errorCode")
                    finish(null)
                }

                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit

                override fun onDiscoveryStarted(serviceType: String) {
                    Log.d(TAG, "Discovery started for $serviceType")
                }

                override fun onDiscoveryStopped(serviceType: String) = Unit

                override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                    @Suppress("DEPRECATION")
                    nsdManager.resolveService(serviceInfo, resolveListener)
                }

                override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit
            }
            discoveryListener = listener

            continuation.invokeOnCancellation {
                runCatching { nsdManager.stopServiceDiscovery(listener) }
            }
            nsdManager.discoverServices(Wire.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        }
    }

    companion object {
        private const val TAG = Prefs.TAG
        private const val LOCK_TAG = "MacDroidSync"
    }
}

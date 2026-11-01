package pl.mwgo.macdroidsync

import android.app.Application

/**
 * Whatever starts this process - a screen the system restores after an
 * update, a camera broadcast, the update broadcast itself, which Samsung may
 * hold back for minutes - the sync comes back with it if the user has it on.
 */
class MacDroidSyncApp : Application() {
    override fun onCreate() {
        super.onCreate()
        SyncService.ensureRunning(this)
    }
}

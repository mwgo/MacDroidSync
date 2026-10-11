package pl.mwgo.macdroidsync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * What the notes app, or any app signed with the same key, tells the sync
 * about the files of a synced folder. Only apps holding
 * [FolderEvents.PERMISSION] get through, see the manifest.
 *
 * - [FolderEvents.FOLDER_CHANGED] with [FolderEvents.EXTRA_PATHS]: it changed
 *   these files, the Mac should look now.
 * - [FolderEvents.FOLDER_EDITING] with [FolderEvents.EXTRA_PATH] and
 *   [FolderEvents.EXTRA_DIRTY]: the file is open with changes not yet saved, so
 *   the Mac's version waits; said again while it stays so.
 *
 * Nothing happens while the sync service is not running: the Mac compares the
 * folders anyway when it next connects.
 */
class FolderEventsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val service = SyncService.running ?: return
        when (intent.action) {
            FolderEvents.FOLDER_CHANGED ->
                service.folderChangedByApp(intent.getStringArrayExtra(FolderEvents.EXTRA_PATHS)?.toList().orEmpty())
            FolderEvents.FOLDER_EDITING -> {
                val path = intent.getStringExtra(FolderEvents.EXTRA_PATH) ?: return
                service.folderEditing(path, intent.getBooleanExtra(FolderEvents.EXTRA_DIRTY, false))
            }
        }
    }
}

/** The broadcasts between MacDroidSync and the apps whose folders it syncs. */
object FolderEvents {
    const val PERMISSION = "pl.mwgo.permission.FOLDER_EVENTS"
    /** App to MacDroidSync: files changed. */
    const val FOLDER_CHANGED = "pl.mwgo.macdroidsync.FOLDER_CHANGED"
    /** App to MacDroidSync: a file is open with unsaved changes, or no longer. */
    const val FOLDER_EDITING = "pl.mwgo.macdroidsync.FOLDER_EDITING"
    /** MacDroidSync to the apps: the sync wrote these files. */
    const val FILES_CHANGED = "pl.mwgo.macdroidsync.FILES_CHANGED"
    const val EXTRA_PATHS = "paths"
    const val EXTRA_PATH = "path"
    const val EXTRA_DIRTY = "dirty"
}

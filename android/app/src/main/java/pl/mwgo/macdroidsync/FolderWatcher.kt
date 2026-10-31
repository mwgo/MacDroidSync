package pl.mwgo.macdroidsync

import android.os.Build
import android.os.FileObserver
import java.io.File

/**
 * Hears of changes anywhere in the synced folders: one [FileObserver] per
 * folder, since one only sees its own folder, and a new one for each folder
 * made while it watches. [onChange] gets the absolute path of what changed, on
 * the observer's thread.
 */
class FolderWatcher(private val onChange: (String) -> Unit) {

    private val observers = HashMap<String, FileObserver>()

    @Synchronized
    fun watch(roots: Collection<File>) {
        stop()
        roots.forEach(::watchTree)
    }

    @Synchronized
    fun stop() {
        observers.values.forEach { it.stopWatching() }
        observers.clear()
    }

    @Synchronized
    private fun watchTree(dir: File) {
        if (!dir.isDirectory || FolderRules.isExcluded(dir.name) || observers.containsKey(dir.absolutePath)) return
        val observer = observe(dir)
        observer.startWatching()
        observers[dir.absolutePath] = observer
        dir.listFiles()?.filter { it.isDirectory }?.forEach(::watchTree)
    }

    @Synchronized
    private fun forget(dir: String) {
        observers.remove(dir)?.stopWatching()
    }

    private fun observe(dir: File): FileObserver {
        val handler: (Int, String?) -> Unit = { event, name ->
            if (name != null && !FolderRules.isExcluded(name)) {
                val child = File(dir, name)
                if (event and (FileObserver.CREATE or FileObserver.MOVED_TO) != 0 && child.isDirectory) watchTree(child)
                onChange(child.absolutePath)
            } else if (event and (FileObserver.DELETE_SELF or FileObserver.MOVE_SELF) != 0) {
                forget(dir.absolutePath)
                onChange(dir.absolutePath)
            }
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            object : FileObserver(dir, MASK) {
                override fun onEvent(event: Int, path: String?) = handler(event, path)
            }
        } else {
            @Suppress("DEPRECATION")
            object : FileObserver(dir.absolutePath, MASK) {
                override fun onEvent(event: Int, path: String?) = handler(event, path)
            }
        }
    }

    private companion object {
        const val MASK = FileObserver.CLOSE_WRITE or FileObserver.CREATE or FileObserver.DELETE or
            FileObserver.MOVED_FROM or FileObserver.MOVED_TO or FileObserver.DELETE_SELF or FileObserver.MOVE_SELF
    }
}

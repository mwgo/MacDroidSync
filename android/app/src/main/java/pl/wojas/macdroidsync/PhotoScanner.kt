package pl.wojas.macdroidsync

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import java.io.InputStream
import java.util.TimeZone

/**
 * The only place on the phone that talks to MediaStore.
 *
 * Kept as thin as it can be: every decision - what is in the window, what has to
 * be hashed, what counts as gone - lives in PhotoSync.kt, where a plain JVM test
 * can reach it. This class reads columns and opens streams, and nothing else.
 */
class PhotoScanner(private val context: Context) {

    /** One row as MediaStore describes it, before any decision is made about it. */
    data class Row(
        val key: String,
        val id: Long,
        val name: String,
        val size: Long,
        val mime: String?,
        val captureAt: Long,
        val dateModified: Long,
        val generation: Long,
        val isVideo: Boolean,
    )

    /**
     * What a scan found, and whether it can be trusted.
     *
     * [complete] is the important field. Only a trustworthy scan may produce
     * tombstones, because an untrustworthy one - a permission narrowed to
     * "selected photos", a MediaStore that threw, a camera folder that is not
     * there - looks exactly like every photo having been deleted.
     */
    data class Scan(
        val rows: List<Row>,
        val complete: Boolean,
        val refusal: String? = null,
    )

    private val resolver: ContentResolver = context.contentResolver

    /**
     * Reads DCIM/Camera. Images and videos are queried separately because from
     * Android 13 they are separate permissions, and a phone that granted one and
     * not the other has to be describable.
     */
    fun scan(): Scan {
        Permissions.mediaRefusal(context)?.let {
            return Scan(emptyList(), complete = false, refusal = it)
        }
        return try {
            val rows = query(video = false) + query(video = true)
            if (rows.isEmpty() && !mediaStoreHasAnything()) {
                // An empty answer from a library that is not there is not "every
                // photo was deleted" - which is exactly how the Mac's delete rule
                // would read it.
                Scan(
                    emptyList(),
                    complete = false,
                    refusal = "nothing was found in ${PhotoKey.CAMERA_PATH}",
                )
            } else {
                Scan(rows, complete = true)
            }
        } catch (error: Exception) {
            Log.w(TAG, "Could not read the camera folder", error)
            Scan(emptyList(), complete = false, refusal = "the camera folder could not be read")
        }
    }

    private fun query(video: Boolean): List<Row> {
        val columns = mutableListOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.MIME_TYPE,
            // The same "datetaken" column on both tables, named from the older
            // constant so it is legal on Android 9 too.
            MediaStore.Images.Media.DATE_TAKEN,
            MediaStore.MediaColumns.DATE_MODIFIED,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            columns.add(MediaStore.MediaColumns.RELATIVE_PATH)
        } else {
            @Suppress("DEPRECATION")
            columns.add(MediaStore.MediaColumns.DATA)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            columns.add(MediaStore.MediaColumns.GENERATION_MODIFIED)
        }

        val selection: String
        val arguments: Array<String>
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // An exact match rather than a LIKE with a wildcard: the wildcard
            // would also take DCIM/Camera Backup and every subfolder, and this
            // feature reads one folder.
            selection = "${MediaStore.MediaColumns.RELATIVE_PATH} = ?"
            arguments = arrayOf(PhotoKey.CAMERA_PATH)
        } else {
            @Suppress("DEPRECATION")
            selection = "${MediaStore.MediaColumns.DATA} LIKE ?"
            arguments = arrayOf("%/${PhotoKey.CAMERA_PATH}%")
        }

        val zoneOffset = TimeZone.getDefault().getOffset(System.currentTimeMillis())
        val rows = mutableListOf<Row>()
        resolver.query(collection(video), columns.toTypedArray(), selection, arguments, null)
            ?.use { cursor ->
                val idColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                val mimeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
                val takenColumn = cursor.getColumnIndex(MediaStore.Images.Media.DATE_TAKEN)
                val modifiedColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
                val pathColumn = cursor.getColumnIndex(
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        MediaStore.MediaColumns.RELATIVE_PATH
                    } else {
                        @Suppress("DEPRECATION")
                        MediaStore.MediaColumns.DATA
                    },
                )
                val generationColumn = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    cursor.getColumnIndex(MediaStore.MediaColumns.GENERATION_MODIFIED)
                } else {
                    -1
                }

                while (cursor.moveToNext()) {
                    val name = cursor.getString(nameColumn) ?: continue
                    val relativePath = relativePath(cursor.getStringOrNull(pathColumn), name)
                    val key = PhotoKey.of(relativePath, name) ?: continue
                    val taken = if (takenColumn >= 0 && !cursor.isNull(takenColumn)) {
                        cursor.getLong(takenColumn)
                    } else {
                        null
                    }
                    rows.add(
                        Row(
                            key = key,
                            id = cursor.getLong(idColumn),
                            name = name,
                            size = cursor.getLong(sizeColumn),
                            mime = cursor.getString(mimeColumn),
                            // The capture time, never the modification time: a
                            // file that was merely copied has a fresh
                            // modification time and would re-enter the window as
                            // if it were new.
                            captureAt = PhotoCaptureDate.resolve(taken, name, zoneOffset),
                            dateModified = cursor.getLong(modifiedColumn),
                            generation = if (generationColumn >= 0) {
                                cursor.getLong(generationColumn)
                            } else {
                                0
                            },
                            isVideo = video,
                        ),
                    )
                }
            }
        return rows
    }

    /**
     * On Android 10 and up the column is already a relative path. On Android 9 it
     * is a full filesystem path, so the folder is taken out of it.
     */
    private fun relativePath(raw: String?, name: String): String {
        if (raw == null) return PhotoKey.CAMERA_PATH
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return raw
        val withoutName = raw.removeSuffix(name)
        val index = withoutName.indexOf(PhotoKey.CAMERA_PATH)
        return if (index >= 0) withoutName.substring(index) else PhotoKey.CAMERA_PATH
    }

    private fun collection(video: Boolean): Uri =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            if (video) {
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            }
        } else if (video) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }

    /**
     * Whether MediaStore holds any image at all, used to tell "nothing new in the
     * camera folder" from "this phone is not describing its media".
     */
    private fun mediaStoreHasAnything(): Boolean = try {
        resolver.query(
            collection(video = false), arrayOf(MediaStore.MediaColumns._ID), null, null, null,
        )?.use { it.count > 0 } ?: false
    } catch (error: Exception) {
        false
    }

    /**
     * Opens one item's **original** bytes.
     *
     * `setRequireOriginal` is what stops MediaStore from stripping the GPS tags
     * out of the bytes it hands over, and it needs ACCESS_MEDIA_LOCATION. Without
     * both, the sync would quietly deliver photos with the location removed - the
     * file would look right and be wrong. So a failure here is reported rather
     * than being answered with redacted bytes.
     */
    fun openOriginal(row: Row): InputStream? {
        val uri = itemUri(row)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                resolver.openInputStream(MediaStore.setRequireOriginal(uri))
            } else {
                // Before scoped storage nothing is redacted, so there is nothing
                // to ask for.
                resolver.openInputStream(uri)
            }
        } catch (error: Exception) {
            Log.w(TAG, "Could not open the original of ${row.name}", error)
            null
        }
    }

    /**
     * The size to announce, read from the descriptor rather than from the SIZE
     * column: the column goes stale, and a stale size would have the Mac reject a
     * perfectly good transfer for a mismatch.
     */
    fun currentSize(row: Row): Long? = try {
        resolver.openAssetFileDescriptor(itemUri(row), "r")?.use { it.length }
    } catch (error: Exception) {
        null
    }

    private fun itemUri(row: Row): Uri =
        collection(row.isVideo).buildUpon().appendPath(row.id.toString()).build()

    private fun android.database.Cursor.getStringOrNull(column: Int): String? =
        if (column >= 0 && !isNull(column)) getString(column) else null

    private companion object {
        private const val TAG = Prefs.TAG
    }
}

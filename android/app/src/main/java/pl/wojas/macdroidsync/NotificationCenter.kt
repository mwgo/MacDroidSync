package pl.wojas.macdroidsync

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat

/**
 * Two ongoing notifications back the same foreground service:
 *
 *  * while no Mac is connected, [CHANNEL_IDLE] carries a silent notification with
 *    a fully transparent icon, so nothing shows up in the status bar. The channel
 *    asks for IMPORTANCE_MIN but Android raises the importance of any foreground
 *    service notification to at least IMPORTANCE_LOW, which is why the icon
 *    itself has to be blank (see drawable/ic_stat_idle).
 *  * [CHANNEL_ACTIVE] posts the real icon the moment a Mac is connected, together
 *    with the clipboard action.
 *
 * A posted notification cannot change its channel, hence the two ids that the
 * service alternates between.
 */
class NotificationCenter(private val context: Context) {

    private val manager = context.getSystemService(NotificationManager::class.java)

    fun createChannels() {
        val idle = NotificationChannel(
            CHANNEL_IDLE,
            context.getString(R.string.notification_channel_idle),
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = context.getString(R.string.notification_channel_idle_description)
            setShowBadge(false)
        }
        val active = NotificationChannel(
            CHANNEL_ACTIVE,
            context.getString(R.string.notification_channel_active),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = context.getString(R.string.notification_channel_active_description)
            setShowBadge(false)
        }
        val events = NotificationChannel(
            CHANNEL_EVENTS,
            context.getString(R.string.notification_channel_events),
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = context.getString(R.string.notification_channel_events_description)
        }
        // The ringing itself is played by Ringer, so the channel stays quiet and
        // only takes care of showing the notification on top of everything.
        val ping = NotificationChannel(
            CHANNEL_PING,
            context.getString(R.string.notification_channel_ping),
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = context.getString(R.string.notification_channel_ping_description)
            setSound(null, null)
            enableVibration(false)
        }
        val transfer = NotificationChannel(
            CHANNEL_TRANSFER,
            context.getString(R.string.notification_channel_transfer),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = context.getString(R.string.notification_channel_transfer_description)
            setShowBadge(false)
        }
        manager.createNotificationChannels(listOf(idle, active, events, ping, transfer))
    }

    fun idleNotification(): Notification =
        NotificationCompat.Builder(context, CHANNEL_IDLE)
            // Transparent on purpose: no status bar icon while disconnected.
            .setSmallIcon(R.drawable.ic_stat_idle)
            .setContentTitle(context.getString(R.string.notification_idle_title))
            .setContentText(context.getString(R.string.notification_idle_text))
            .setContentIntent(mainActivityIntent())
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setSilent(true)
            .setShowWhen(false)
            .setOngoing(true)
            .build()

    fun activeNotification(macName: String): Notification =
        NotificationCompat.Builder(context, CHANNEL_ACTIVE)
            .setSmallIcon(R.drawable.ic_stat_sync)
            .setContentTitle(context.getString(R.string.notification_active_title))
            .setContentText(context.getString(R.string.notification_active_text, macName))
            .setContentIntent(mainActivityIntent())
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setOngoing(true)
            .addAction(
                R.drawable.ic_stat_sync,
                context.getString(R.string.notification_action_send),
                PendingIntent.getActivity(
                    context,
                    REQUEST_SEND,
                    ClipboardBridgeActivity.readIntent(context),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .addAction(
                R.drawable.ic_stat_sync,
                context.getString(R.string.notification_action_disconnect),
                PendingIntent.getService(
                    context,
                    REQUEST_DISCONNECT,
                    Intent(context, SyncService::class.java).setAction(SyncService.ACTION_STOP),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .build()

    /**
     * Shown while the phone is ringing. Silencing it works from the action, from
     * swiping the notification away, or by simply waiting for the ring to end.
     */
    fun showPing(macName: String) {
        val silence = PendingIntent.getService(
            context,
            REQUEST_SILENCE,
            Intent(context, SyncService::class.java).setAction(SyncService.ACTION_SILENCE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_PING)
            .setSmallIcon(R.drawable.ic_stat_sync)
            .setContentTitle(context.getString(R.string.notification_ping_title, macName))
            .setContentText(context.getString(R.string.notification_ping_text))
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(silence)
            .setDeleteIntent(silence)
            .addAction(R.drawable.ic_stat_sync, context.getString(R.string.notification_action_silence), silence)
            .setAutoCancel(true)
            .build()
        manager.notify(ID_PING, notification)
    }

    /**
     * Fallback for the rare case where Android refuses the background activity
     * start: the user can tap the notification to apply the clipboard manually.
     */
    fun showPendingClipboard(macName: String, text: String) {
        val notification = NotificationCompat.Builder(context, CHANNEL_EVENTS)
            .setSmallIcon(R.drawable.ic_stat_sync)
            .setContentTitle(context.getString(R.string.notification_pending_title, macName))
            .setContentText(context.getString(R.string.notification_pending_text))
            .setStyle(NotificationCompat.BigTextStyle().bigText(text.take(200)))
            .setContentIntent(
                PendingIntent.getActivity(
                    context,
                    REQUEST_APPLY,
                    ClipboardBridgeActivity.writeIntent(context, text),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            )
            .setAutoCancel(true)
            .build()
        manager.notify(ID_PENDING, notification)
    }

    /**
     * Progress of the file currently going to the Mac. Called often, so it stays
     * on a low importance channel and only alerts once.
     */
    fun showTransfer(name: String, sent: Long, total: Long, queued: Int) {
        val percent = if (total > 0) ((sent * 100) / total).toInt().coerceIn(0, 100) else 0
        val builder = NotificationCompat.Builder(context, CHANNEL_TRANSFER)
            .setSmallIcon(R.drawable.ic_stat_sync)
            .setContentTitle(context.getString(R.string.notification_transfer_title))
            .setContentText(
                if (queued > 0) {
                    context.getString(R.string.notification_transfer_text_queued, name, queued)
                } else {
                    name
                }
            )
            .setProgress(100, percent, total <= 0)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setOngoing(true)
            .setContentIntent(mainActivityIntent())
        manager.notify(ID_TRANSFER, builder.build())
    }

    /** Progress of a file arriving from the Mac. */
    fun showIncomingTransfer(name: String, received: Long, total: Long) {
        val percent = if (total > 0) ((received * 100) / total).toInt().coerceIn(0, 100) else 0
        val notification = NotificationCompat.Builder(context, CHANNEL_TRANSFER)
            .setSmallIcon(R.drawable.ic_stat_sync)
            .setContentTitle(context.getString(R.string.notification_incoming_title))
            .setContentText(name)
            .setProgress(100, percent, total <= 0)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setOngoing(true)
            .setContentIntent(mainActivityIntent())
            .build()
        manager.notify(ID_INCOMING, notification)
    }

    /**
     * A file from the Mac landed in Download. The Open action hands the reader a
     * one shot read permission on the MediaStore item.
     */
    fun showFileReceived(saved: IncomingFiles.Saved) {
        val builder = NotificationCompat.Builder(context, CHANNEL_EVENTS)
            .setSmallIcon(R.drawable.ic_stat_sync)
            .setContentTitle(context.getString(R.string.notification_file_received_title))
            .setContentText(saved.displayName)
            .setStyle(NotificationCompat.BigTextStyle().bigText(saved.path))
            .setAutoCancel(true)

        val uri = saved.uri
        if (uri != null) {
            val view = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, context.contentResolver.getType(uri))
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            val open = PendingIntent.getActivity(
                context,
                REQUEST_OPEN,
                view,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.setContentIntent(open)
                .addAction(R.drawable.ic_stat_sync, context.getString(R.string.notification_action_open), open)
        } else {
            builder.setContentIntent(mainActivityIntent())
        }
        manager.notify(ID_FILE_RECEIVED, builder.build())
    }

    /** Final word on one file, so the user knows it landed on the Mac. */
    fun showFileResult(name: String, ok: Boolean, detail: String?) {
        val title = if (ok) {
            context.getString(R.string.notification_file_sent_title)
        } else {
            context.getString(R.string.notification_file_failed_title)
        }
        val text = if (ok) name else context.getString(R.string.notification_file_failed_text, name, detail.orEmpty())
        val notification = NotificationCompat.Builder(context, CHANNEL_EVENTS)
            .setSmallIcon(R.drawable.ic_stat_sync)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(mainActivityIntent())
            .setAutoCancel(true)
            .build()
        manager.notify(ID_FILE_RESULT, notification)
    }

    fun cancel(id: Int) = manager.cancel(id)

    private fun mainActivityIntent(): PendingIntent = PendingIntent.getActivity(
        context,
        REQUEST_MAIN,
        Intent(context, MainActivity::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    companion object {
        const val CHANNEL_IDLE = "sync_idle"
        const val CHANNEL_ACTIVE = "sync_active"
        const val CHANNEL_EVENTS = "sync_events"
        const val CHANNEL_PING = "sync_ping"
        const val CHANNEL_TRANSFER = "sync_transfer"

        const val ID_IDLE = 10
        const val ID_ACTIVE = 11
        const val ID_PING = 20
        const val ID_PENDING = 21
        const val ID_FILE_RESULT = 22
        const val ID_FILE_RECEIVED = 23
        const val ID_TRANSFER = 30
        const val ID_INCOMING = 31

        private const val REQUEST_MAIN = 1
        private const val REQUEST_SEND = 2
        private const val REQUEST_DISCONNECT = 3
        private const val REQUEST_APPLY = 4
        private const val REQUEST_SILENCE = 5
        private const val REQUEST_OPEN = 6
    }
}

package app.pushify.sdk

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

/** Delivers a locally scheduled trial reminder without starting the host app. */
public class TrialReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val title = intent.getStringExtra(EXTRA_TITLE)?.takeIf(String::isNotBlank) ?: return
        val body = intent.getStringExtra(EXTRA_BODY)?.takeIf(String::isNotBlank) ?: return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Trial reminders", NotificationManager.IMPORTANCE_DEFAULT))
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL_ID) else Notification.Builder(context)
        val subtitle = intent.getStringExtra(EXTRA_SUBTITLE)?.takeIf(String::isNotBlank)
        val notification = builder.setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body).setSummaryText(subtitle))
            .setAutoCancel(true)
            .build()
        manager.notify(intent.getIntExtra(EXTRA_NOTIFICATION_ID, title.hashCode()), notification)
    }

    public companion object {
        public const val CHANNEL_ID = "pushify_trial_reminders"
        public const val EXTRA_TITLE = "app.pushify.trial_reminder.title"
        public const val EXTRA_SUBTITLE = "app.pushify.trial_reminder.subtitle"
        public const val EXTRA_BODY = "app.pushify.trial_reminder.body"
        public const val EXTRA_NOTIFICATION_ID = "app.pushify.trial_reminder.notification_id"
    }
}

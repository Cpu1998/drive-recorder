package com.zhangkeyou.drive_recorder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * 行车记录前台服务（foregroundServiceType = location）。
 *
 * 职责：
 * 1. 显示常驻通知，向系统声明"正在使用位置"的前台服务类型，
 *    使 App 退到后台/熄屏后进程不被冻结，高德定位回调与传感器采样得以继续；
 * 2. 持有一个 partial WakeLock，防止熄屏打盹（doze）时 30s 断连宽限计时被延迟；
 * 3. 本服务不做业务逻辑，纯保活壳；定位/传感器/存储全部在 Flutter 侧完成。
 *
 * START_STICKY：进程被杀后系统会尝试重启服务（Flutter 引擎随之重启，
 * 但不会自动恢复记录，见 README 遗留事项说明）。
 */
class ForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "drive_recording"
        const val NOTIFICATION_ID = 10086
        const val ACTION_START = "com.zhangkeyou.drive_recorder.action.START"
        const val ACTION_STOP = "com.zhangkeyou.drive_recorder.action.STOP"

        fun start(context: Context) {
            val intent = Intent(context, ForegroundService::class.java)
                .setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, ForegroundService::class.java).setAction(ACTION_STOP)
            )
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            releaseWakeLock()
            return START_NOT_STICKY
        }
        startInForeground()
        acquireWakeLock()
        return START_STICKY
    }

    private fun startInForeground() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "行车记录",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "行车轨迹记录进行中"
                    setShowBadge(false)
                }
            )
        }

        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("行车记录进行中")
            .setContentText("正在记录行车轨迹与驾驶事件")
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(pendingIntent)
            .build()

        // Android 10+ 需要以 location 类型启动前台服务（需 FOREGROUND_SERVICE_LOCATION 权限）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "drive_recorder:recording").apply {
            setReferenceCounted(false)
            acquire(6 * 60 * 60 * 1000L) // 最长 6 小时，防止泄漏
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }
}

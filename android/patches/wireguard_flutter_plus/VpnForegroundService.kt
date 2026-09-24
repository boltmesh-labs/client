/*
 * This fragment replaces the VpnForegroundService tail in the pinned
 * wireguard_flutter_plus Android source. The Gradle build inserts it after the
 * plugin's package/import declarations; it is not a standalone source file.
 */
class VpnForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "vpn_foreground_channel"
        const val NOTIFICATION_ID = 101
        private const val ACTION_START = "START"
        private const val EXTRA_VPN_DISPLAY_NAME = "vpnDisplayName"
        private const val NOTIFICATION_REQUEST_CODE = 101
        private const val MAIN_ACTIVITY_CLASS = "com.boltmesh.boltmesh.MainActivity"
        private const val UPDATE_INTERVAL_MS = 1_000L
    }

    private val handler = Handler(Looper.getMainLooper())
    private var vpnDisplayName = "WireGuard VPN"
    private var foreground = false

    private val updateRunnable = object : Runnable {
        override fun run() {
            if (!foreground) return

            val contentText = "↑ ${VpnTrafficStats.uploadSpeed} | " +
                "↓ ${VpnTrafficStats.downloadSpeed} | ${VpnTrafficStats.duration}"
            updateNotification(contentText)
            handler.postDelayed(this, UPDATE_INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        // Do not enter the foreground here.  A null onStartCommand() intent is
        // how Android recreates a sticky service after process death; the
        // tunnel and Flutter engine are gone in that case, so a notification
        // created from onCreate() would be a lie.
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_START) {
            vpnDisplayName = intent.getStringExtra(EXTRA_VPN_DISPLAY_NAME)
                ?: "WireGuard VPN"
            startInForeground(buildNotification("VPN is running"))
            handler.removeCallbacks(updateRunnable)
            handler.post(updateRunnable)
        } else {
            // STOP, a null restart intent, and any unknown action must never
            // leave a foreground notification behind.  The plugin only emits
            // ACTION_START after its backend has accepted Tunnel.State.UP.
            clearForeground()
            stopSelf(startId)
        }

        // A process death destroys the in-process GoBackend/TUN.  Never ask
        // Android to recreate this keep-alive service with a null intent.
        return START_NOT_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "VPN Service",
                NotificationManager.IMPORTANCE_LOW,
            )
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        }
    }

    private fun startInForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // Mark the service live only after Android accepted the promotion.
        foreground = true
    }

    private fun buildNotification(contentText: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent().setClassName(packageName, MAIN_ACTIVITY_CLASS)
        launchIntent.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP,
        )
        val contentIntent = PendingIntent.getActivity(
            this,
            NOTIFICATION_REQUEST_CODE,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(vpnDisplayName)
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(contentIntent)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()
    }

    private fun clearForeground() {
        foreground = false
        handler.removeCallbacks(updateRunnable)
        stopForeground(STOP_FOREGROUND_REMOVE)
        getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }

    private fun updateNotification(contentText: String) {
        if (!foreground) return
        getSystemService(NotificationManager::class.java)
            ?.notify(NOTIFICATION_ID, buildNotification(contentText))
    }

    override fun onDestroy() {
        clearForeground()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}

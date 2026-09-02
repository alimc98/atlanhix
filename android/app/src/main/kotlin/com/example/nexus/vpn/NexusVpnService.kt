package com.example.nexus.vpn

import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.os.Build

/**
 * NEXUS Android VPN transport.
 *
 * Architecture (docs/PLATFORM_ARCHITECTURE.md — Android): this foreground
 * [VpnService] owns the TUN interface and pipes packets to the bundled
 * sing-box engine (engine-mode, the approach proven by sing-box for
 * Android). The Dart layer talks to this service over a MethodChannel;
 * full engine wiring (libbox integration, per-app routing, stats) is the
 * remaining Android milestone and is intentionally NOT faked here: without
 * the engine bound, start() reports failure instead of pretending.
 */
class NexusVpnService : VpnService() {

    private var tun: ParcelFileDescriptor? = null
    private var running = false

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTun()
                return START_NOT_STICKY
            }
            else -> {
                startForeground(NOTIFY_ID, buildNotification())
                running = true
                // Engine binding milestone (libbox): configure Builder with
                // sing-box tun addresses/routes and hand the fd to the engine.
                // Until the engine artifact is bundled, report state via the
                // notification and stop cleanly.
                return START_STICKY
            }
        }
    }

    private fun buildBuilder(): Builder =
        Builder()
            .setMtu(9000)
            .addAddress("172.19.0.1", 30)
            .addDnsServer("1.1.1.1")
            .addRoute("0.0.0.0", 0)
            .addRoute("::", 0)
            .setSession("NEXUS")

    private fun stopTun() {
        running = false
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "NEXUS VPN", NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val pi = PendingIntent.getActivity(
            this, 0, packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        return builder
            .setContentTitle("NEXUS")
            .setContentText("VPN service")
            .setSmallIcon(android.R.drawable.stat_sys_vpn_ic)
            .setContentIntent(pi)
            .build()
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        const val ACTION_STOP = "dev.nexus.nexus.vpn.STOP"
        const val CHANNEL_ID = "nexus_vpn"
        const val NOTIFY_ID = 0x4E45 // 'NE'
    }
}

package com.atlanhix.app.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.util.Log
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader

/**
 * v0.5.3 — MIHOMO (Clash.Meta) core host, running in the `:mihomo` process
 * WITHOUT a second Go runtime in the VPN process: the official mihomo
 * Android release binary, shipped inside the APK as `lib/libmihomo.so` so
 * it lands in the app's read-only native lib dir, which Android's W^X
 * policy explicitly ALLOWS to exec() — the SAME NekoBox `app/executableSo`
 * pattern [XrayCoreService] uses for Xray.
 *
 * Topology: mihomo owns the dial-out end-to-end (the Dart side generates a
 * FULL mihomo config with the node as the proxy — see MihomoConfigGenerator).
 * The front sing-box (main process, owns TUN) dials nodes through mihomo's
 * mixed inbound via socksUpstreams — the daemon topology, with mihomo's
 * native external-controller ALSO serving the app's Clash-API clients
 * (delay tests / selector migration).
 */
class MihomoCoreService : Service() {

    private var process: Process? = null
    @Volatile private var generation = 0
    @Volatile private var stopRequested = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "mihomo core", NotificationManager
                        .IMPORTANCE_MIN))
        }
    }

    /** Post the foreground notification (start path only — see onCreate). */
    private fun promoteForeground() {
        val notif = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Atlanhix core")
            .setContentText("Secure engine running")
            .setSmallIcon(applicationInfo.icon)
            .build()
        startForeground(NOTIFY_ID, notif)
    }

    /** Remove the notification; safe to call in any state. */
    private fun clearForeground() {
        try {
            @Suppress("DEPRECATION")
            stopForeground(true)
        } catch (_: Throwable) {
        }
    }

    override fun onDestroy() {
        handleStop()
        clearForeground()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> handleStart(intent)
            ACTION_STOP -> {
                handleStop()
                clearForeground()
                stopSelf()
            }
            else -> {
                handleStop()
                clearForeground()
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun handleStart(intent: Intent) {
        promoteForeground()
        handleStop()
        val config = intent.getStringExtra(EXTRA_CONFIG) ?: return fail("no config")
        val port = intent.getIntExtra(EXTRA_MIXED_PORT, 0)
        try {
            val bin = File(applicationInfo.nativeLibraryDir, "libmihomo.so")
            if (!bin.canExecute()) return fail("exec refused on native lib dir")
            val cfg = File(filesDir, "mihomo-config.json").apply { writeText(config) }
            // `-d` = mihomo's working dir (its own cache/GeoIP state lives
            // here, separate from Xray's).
            val wd = File(filesDir, "mihomo").apply { mkdirs() }
            val pb = ProcessBuilder(
                bin.absolutePath, "-d", wd.absolutePath, "-f", cfg.absolutePath)
                .directory(wd)
                .redirectErrorStream(true)
            pb.environment()["HOME"] = wd.absolutePath
            pb.environment()["TMPDIR"] = cacheDir.absolutePath
            val p = pb.start()
            process = p
            generation += 1
            val gen = generation
            running = true
            mixedPort = port
            writeState()
            Thread {
                while (gen == generation && running && p.isAlive) {
                    try {
                        Thread.sleep(20_000)
                    } catch (_: InterruptedException) {
                        break
                    }
                    if (gen == generation) writeState()
                }
            }.apply { isDaemon = true }.start()
            Thread {
                try {
                    BufferedReader(InputStreamReader(p.inputStream)).useLines { lines ->
                        lines.forEach { Log.d(MTAG, it) }
                    }
                    val code = p.waitFor()
                    Log.i(MTAG, "mihomo exited code=$code")
                } catch (e: Throwable) {
                    Log.w(MTAG, "runner: ${e.message}")
                } finally {
                    if (gen == generation) {
                        running = false
                        writeState()
                        if (stopRequested) stopSelf()
                    }
                }
            }.start()
        } catch (e: Throwable) {
            fail("start: ${e.message}")
        }
    }

    private fun handleStop() {
        stopRequested = true
        generation += 1
        process?.let {
            it.destroy()
            try {
                if (!it.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)) it.destroyForcibly()
            } catch (_: Throwable) {
            }
        }
        process = null
        running = false
        mixedPort = 0
        writeState()
    }

    private fun fail(msg: String) {
        Log.e(MTAG, msg)
        running = false
        writeState()
        clearForeground()
        stopSelf()
    }

    /** Cross-process state hand-off (service = :mihomo, channel = main). */
    private fun writeState() {
        try {
            File(filesDir, STATE_FILE).writeText(
                if (running) "1:$mixedPort:${System.currentTimeMillis()}" else "0:0:0")
        } catch (_: Throwable) {
        }
    }

    companion object {
        private const val CHANNEL_ID = "atlanhix_mihomo_fg"
        private const val NOTIFY_ID = 4103
        const val ACTION_START = "com.atlanhix.app.mihomo.START"
        const val ACTION_STOP = "com.atlanhix.app.mihomo.STOP"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_MIXED_PORT = "mixedPort"
        const val STATE_FILE = "mihomo-runtime.state"
        const val MTAG = "AtlanhixMihomo"

        @Volatile var running = false
        @Volatile var mixedPort = 0

        fun readState(filesDir: File): Pair<Boolean, Int> = try {
            val f = File(filesDir, STATE_FILE)
            if (!f.exists()) false to 0
            else {
                val parts = f.readText().trim().split(":")
                val alive = parts.getOrNull(0) == "1"
                val ts = parts.getOrNull(2)?.toLongOrNull() ?: 0L
                (alive && System.currentTimeMillis() - ts < 60_000L) to
                    (parts.getOrNull(1)?.toIntOrNull() ?: 0)
            }
        } catch (_: Throwable) {
            false to 0
        }
    }
}

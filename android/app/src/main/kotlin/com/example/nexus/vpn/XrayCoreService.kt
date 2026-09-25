package com.example.nexus.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.app.Service
import android.os.IBinder
import android.util.Log
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader

/**
 * v0.4.3 — Xray core host running in the `:xray` process WITHOUT a second
 * Go runtime: the official Xray Android release binary, shipped inside the
 * APK as `lib/xray_core.so` so it lands in the app's read-only native lib
 * dir, which Android's W^X policy (Android-Docs, "app-data-file-execute-
 * restrictions") explicitly ALLOWS to exec() — unlike the app data dir.
 * This is the NekoBox `app/executableSo` pattern, applied to Xray itself.
 *
 * The binary listens on a local SOCKS5 port; the front sing-box (main
 * process, owns TUN) dials nodes through it via singBox socksUpstreams —
 * exactly the v2rayNG daemon topology, minus the gomobile libv2ray AAR
 * (which conflicts with libbox's go.Seq/libgojni).
 */
class XrayCoreService : Service() {

    private var process: Process? = null
    @Volatile private var generation = 0
    @Volatile private var stopRequested = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        // v0.4.4: MIUI/Android kills plain background services ('Stopping
        // service due to app idle' — measured on Mi 9T 2026-09-15, THE root
        // cause of xhttp nodes never connecting on the phone while PC's
        // xray.exe worked). Foreground + notification = untouchable.
        //
        // v0.4.9 §user-fix (notification survived app close): the channel
        // is created HERE, but startForeground moved OUT of onCreate —
        // merely constructing the service (even for an ACTION_STOP that
        // arrives after a failed start) used to post the "Atlanhix core"
        // notification with nothing ever removing it. The notification now
        // appears only while a start is being handled and is torn down on
        // stop / start-failure / destroy.
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Xray core", NotificationManager
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
        // Last line of defense: whatever path destroyed us (stopSelf,
        // fail, system), the core dies and the notification goes — no
        // orphaned "Atlanhix core" after the app is closed.
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
            // v0.4.9 §user-fix: null action = OS redelivery. START_NOT_STICKY
            // cannot fully prevent a queued redelivery after the runner died;
            // answer by standing down instead of promoting a notification
            // with no config (the old silent fall-through left the service
            // alive doing nothing, keeping the pill on screen).
            else -> {
                handleStop()
                clearForeground()
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun handleStart(intent: Intent) {
        // Foreground FIRST: this action arrives via startForegroundService
        // (API 26+) which requires startForeground() within 5s of delivery
        // even when the attempt is about to fail — and fail() below tears
        // the notification right back down again.
        promoteForeground()
        handleStop()
        val config = intent.getStringExtra(EXTRA_CONFIG) ?: return fail("no config")
        val port = intent.getIntExtra(EXTRA_SOCKS_PORT, 0)
        try {
            val bin = File(applicationInfo.nativeLibraryDir, "libxray_core.so")
            if (!bin.canExecute()) return fail("exec refused on native lib dir")
            val cfg = File(filesDir, "xray-config.json").apply { writeText(config) }
            val wd = filesDir
            val pb = ProcessBuilder(bin.absolutePath, "run", "-c", cfg.absolutePath)
                .directory(wd)
                .redirectErrorStream(true)
            pb.environment()["HOME"] = wd.absolutePath
            pb.environment()["TMPDIR"] = cacheDir.absolutePath
            val p = pb.start()
            process = p
            generation += 1
            val gen = generation
            running = true
            socksPort = port
            writeState()
            // Heartbeat: readState() treats the file as stale after 60s —
            // refresh while alive so a long session never looks dead.
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
            // Run/await the core OFF the service main thread — otherwise a
            // later ACTION_STOP intent could never be delivered (onStart-
            // Command is serialized on the main looper).
            Thread {
                try {
                    BufferedReader(InputStreamReader(p.inputStream)).useLines { lines ->
                        lines.forEach { Log.d(XTAG, it) }
                    }
                    val code = p.waitFor()
                    Log.i(XTAG, "xray exited code=$code")
                } catch (e: Throwable) {
                    Log.w(XTAG, "runner: ${e.message}")
                } finally {
                    // Only the CURRENT generation may flip the shared state —
                    // a restarted core's stale watcher must not mark it dead.
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
        socksPort = 0
        writeState()
    }

    private fun fail(msg: String) {
        Log.e(XTAG, msg)
        running = false
        writeState()
        // v0.4.9 §user-fix: a failed start used to leave the foreground
        // notification up forever (nothing stopped the service) — the
        // stuck "atlanhix core" after closing the app. Drop it now.
        clearForeground()
        stopSelf()
    }

    /** Cross-process state hand-off (service = :xray, channel = main). */
    private fun writeState() {
        try {
            File(filesDir, STATE_FILE).writeText(
                if (running) "1:$socksPort:${System.currentTimeMillis()}" else "0:0:0")
        } catch (_: Throwable) {
        }
    }

    companion object {
        private const val CHANNEL_ID = "atlanhix_xray_fg"
        private const val NOTIFY_ID = 4102
        const val ACTION_START = "com.example.nexus.xray.START"
        const val ACTION_STOP = "com.example.nexus.xray.STOP"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_SOCKS_PORT = "socksPort"
        const val STATE_FILE = "xray-runtime.state"
        const val XTAG = "AtlanhixXray"

        @Volatile var running = false
        @Volatile var socksPort = 0

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

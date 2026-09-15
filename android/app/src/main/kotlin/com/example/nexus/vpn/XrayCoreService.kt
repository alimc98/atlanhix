package com.example.nexus.vpn

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

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> handleStart(intent)
            ACTION_STOP -> handleStop()
        }
        return START_NOT_STICKY
    }

    private fun handleStart(intent: Intent) {
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

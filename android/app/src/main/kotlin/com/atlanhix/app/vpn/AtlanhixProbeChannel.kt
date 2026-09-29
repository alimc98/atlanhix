package com.atlanhix.app.vpn

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * v0.4.9 §user ("تست پینگ وقتی برنامه تازه باز شده کار نمی‌کند") — a
 * TRANSIENT libbox engine for REAL end-to-end delay tests when NO VPN is
 * connected. The main engine lives in the VPN service (separate process) and
 * its Clash API only exists while the tunnel is up; before the first connect
 * there was nothing to test through and every node read "engine-off".
 *
 * This channel runs a second libbox Box INSIDE the main app process with a
 * pure proxy config (mixed inbound 127.0.0.1:7891 + clash_api
 * 127.0.0.1:9090, secret `probe-local`) and NO tun inbound — so no VpnService
 * consent, no TUN, no notification. Dart builds the config for a batch of
 * nodes (single selected outbound per batch), measures real URL delays via
 * the Clash API, and stops the engine after an idle gap.
 *
 * Channel: `dev.atlanhix/probe`
 *   probeStart(config) -> {ok, already?, error?}
 *   probeStop()        -> {ok}
 *
 * The engine REUSES [LibboxEngine] verbatim (libbox setup, default-interface
 * monitor, redaction, engine lifecycle): the only difference is the platform
 * interface — it is NOT a VpnService, so autoDetectInterfaceControl cannot
 * protect() fds. That is correct here: with no active VPN there is nothing
 * to protect from, sockets ride the physical network directly.
 */
class AtlanhixProbeChannel(private val activity: android.app.Activity) {

    private var engine: LibboxEngine? = null
    private var probeError: String? = null

    @Synchronized
    fun handle(method: String, arg: JSONObject?): JSONObject = when (method) {
        "probeStart" -> probeStart(arg ?: JSONObject())
        "probeStop" -> probeStop()
        else -> JSONObject().put("ok", false).put("error", "unknown method: $method")
    }

    private fun probeStart(arg: JSONObject): JSONObject {
        val config = arg.optString("config")
        if (config.isEmpty()) {
            return JSONObject().put("ok", false).put("error", "no config")
        }
        // v0.4.9 §cache-fix: the probe Box gets its OWN libbox working dir —
        // it shares the main process with the VPN service, and both
        // instances fighting over one cache.db made the tunnel start die
        // with `initialize cache-file: timeout` (device 2026-09-25 19:57).
        val probeWorkingDir = File(activity.filesDir, "probe-engine").apply { mkdirs() }
        // An engine from a previous batch (or a previous app run — the Dart
        // singleton dies with the process while this object survives) is
        // replaced by the fresh config. startOrReloadService on a live server
        // would reload; an explicit restart keeps the generation story simple.
        if (engine?.isRunning == true) {
            probeIdle = false // latch: a tunnel start may not race this stop
            stopLocked()
        }
        val platform = object : AtlanhixPlatformInterface {
            override fun context(): Context = activity.applicationContext

            // v0.4.9 §probe-fix ("test all nodes" red on a fresh app open):
            // the interface default returns TRUE, which makes libbox call
            // autoDetectInterfaceControl(fd) before every upstream dial.
            // This object is NOT a VpnService — that path logged
            // AUTO_DETECT_PROTECT_FAILED and ABORTED each dial, so every
            // node measured 502/timeout even though the engine was UP and
            // direct dials worked. There is no VPN to protect from here:
            // let libbox use its OWN default-interface detection (fed by
            // DefaultInterfaceMonitor's updateDefaultInterface pushes) and
            // never ask this process to protect a socket.
            override fun usePlatformAutoDetectInterfaceControl(): Boolean = false

            // The probe config has NO tun inbound, so libbox never dials
            // this — but the interface member is abstract, so it must be
            // declared. Throw honestly if it is ever reached.
            override fun openTunForBox(options: io.nekohasekai.libbox.TunOptions): Int =
                throw UnsupportedOperationException("probe engine has no TUN")

            // libbox PlatformInterface's own abstract member — the probe
            // engine is NOT a VpnService, so route it to openTunForBox.
            override fun openTun(options: io.nekohasekai.libbox.TunOptions): Int =
                openTunForBox(options)
        }
        val listener = object : EngineEvents {
            override fun onStarted() { probeError = null }
            override fun onFailed(reason: String) { probeError = reason }
            override fun onCrashed(reason: String) { probeError = reason }
            override fun onStopped() {}
        }
        probeError = null
        val e = LibboxEngine(activity.applicationContext, platform)
        engine = e
        // Parses + validates + starts the Box inline; throws on an invalid
        // config (caught by the channel boundary in MainActivity → {ok:false}).
        e.start(config, emptyList(), emptyList(), listener,
            workingPathOverride = probeWorkingDir.absolutePath)
        return if (e.isRunning) {
            JSONObject().put("ok", true)
        } else {
            JSONObject().put("ok", false)
                .put("error", probeError ?: "probe engine did not start")
        }
    }

    private fun probeStop(): JSONObject {
        stopLocked()
        return JSONObject().put("ok", true)
    }

    @Synchronized
    private fun stopLocked() {
        try {
            engine?.stop()
        } catch (_: Exception) {}
        engine = null
        // v0.5.2 §first-connect-fix: the tunnel startTunnel() waits on this
        // latch — the probe Box must be FULLY stopped (its native close
        // joined) before the VPN engine reuses the shared libbox state,
        // otherwise both Boxes race cache.db in the same process and the
        // FIRST tunnel start dies with `initialize cache-file: timeout`.
        probeIdle = true
    }

    companion object {
        const val CHANNEL = "dev.atlanhix/probe"

        /** @see stopLocked */
        @Volatile @JvmStatic var probeIdle: Boolean = true
    }
}

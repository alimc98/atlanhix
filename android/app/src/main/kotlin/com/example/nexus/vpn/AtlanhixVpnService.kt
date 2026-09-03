package com.example.nexus.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import org.json.JSONObject

/**
 * Atlanhix Android VPN transport (v0.3.0 §3–§7).
 *
 * Owns the TUN interface and hands its file descriptor to a real tunneling
 * engine ([VpnEngine]). States are driven by ACTUAL runtime events only:
 * this service never reports CONNECTED by itself — the Dart side flips to
 * connected only after a real connectivity probe through the tunnel, so a
 * start() that merely returns cannot fake a tunnel (§5).
 *
 * Lifecycle: Dart → platform channel (MainActivity) → startService/stopService
 * → onStartCommand → Builder → establish() fd → engine.start().
 * Restart handling: START_STICKY + onRevoke cleanup. A second start while an
 * engine session is active is rejected (no multiple simultaneous engines).
 */
class AtlanhixVpnService : VpnService() {

    private var tun: ParcelFileDescriptor? = null
    private var engine: VpnEngine? = null

    private fun setState(s: State, detail: String? = null) {
        state = s
        stateDetail = detail
        updateNotification()
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            Action.STOP -> {
                shutdown()
                return START_NOT_STICKY
            }
            Action.START -> {
                // Foreground first — Android requires it before long work.
                startForeground(NOTIFY_ID, buildNotification())
                val s = state
                if (s != State.IDLE && s != State.STOPPED && s != State.FAILED) {
                    setState(State.FAILED, "start while $s — session already active")
                    return START_STICKY
                }
                setState(State.PREPARING)
                startTunnel()
            }
            else -> {
                // System restart delivery: rebuild the tunnel if we were up.
                if (state == State.CONNECTED || state == State.VALIDATING) {
                    setState(State.RECONNECTING)
                    shutdownTunnelOnly()
                    startTunnel()
                }
            }
        }
        return START_STICKY
    }

    // ------------------------------------------------------------------ TUN

    private fun startTunnel() {
        val config = pendingConfig
        if (config == null) {
            setState(State.FAILED, "no config handoff received")
            return
        }
        try {
            val b = Builder()
                .setMtu(config.optInt("mtu", 9000))
                .setSession("Atlanhix")
                .addAddress(
                    config.getString("inet4Address"),
                    config.optInt("inet4Prefix", 30)
                )
            val inet6 = config.optString("inet6Address", "")
            if (inet6.isNotEmpty()) {
                b.addAddress(inet6, config.optInt("inet6Prefix", 126))
            }
            // §7: DNS resolves through the tunnel — the resolver list comes
            // from the generated sing-box DNS config, never plaintext outside.
            val dns = config.optJSONArray("dns") ?: org.json.JSONArray()
            for (i in 0 until dns.length()) {
                b.addDnsServer(dns.getString(i))
            }
            val routes = config.optJSONArray("routes") ?: org.json.JSONArray()
            for (i in 0 until routes.length()) {
                val parts = routes.getString(i).split("/")
                b.addRoute(parts[0], if (parts.size > 1) parts[1].toInt() else 0)
            }
            applyPerAppRouting(b, config)
            b.setBlocking(false)

            val fd = b.establish()
            if (fd == null) {
                setState(State.FAILED, "establish() returned null — VPN permission revoked?")
                shutdownTunnelOnly()
                return
            }
            tun = fd
            setState(State.STARTING)
            val eng = engine ?: UnavailableEngine()
            engine = eng
            eng.start(config.toString(), fd.fd, engineEvents)
            // State advances ONLY via engineEvents + Dart-side probe (§5).
        } catch (e: Exception) {
            setState(State.FAILED, "tun setup failed: ${e.message}")
            shutdownTunnelOnly()
        }
    }

    /** §6 per-app routing: include-list wins over exclude-list. */
    private fun applyPerAppRouting(b: Builder, config: JSONObject) {
        val include = config.optJSONArray("includeApps")
        if (include != null && include.length() > 0) {
            for (i in 0 until include.length()) {
                val pkg = include.getString(i)
                if (validatePackage(pkg)) b.addAllowedApplication(pkg)
            }
        } else {
            val exclude = config.optJSONArray("excludeApps") ?: return
            for (i in 0 until exclude.length()) {
                try {
                    b.addDisallowedApplication(exclude.getString(i))
                } catch (e: PackageManager.NameNotFoundException) {
                    // Unknown package: skipped (documented limitation,
                    // docs/ANDROID_VPN.md §per-app).
                }
            }
        }
    }

    private fun validatePackage(pkg: String): Boolean = try {
        packageManager.getPackageInfo(pkg, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    // ------------------------------------------------------- engine events

    private val engineEvents = object : EngineEvents {
        override fun onStarted() = setState(State.VALIDATING)
        override fun onFailed(reason: String) {
            setState(State.FAILED, reason)
            shutdownTunnelOnly()
        }
        override fun onCrashed(reason: String) {
            setState(State.RECONNECTING)
            shutdownTunnelOnly()
            startTunnel()
        }
        override fun onStopped() = setState(State.STOPPED)
    }

    // ------------------------------------------------------------- shutdown

    private fun shutdown() {
        setState(State.STOPPING)
        shutdownTunnelOnly()
        setState(State.STOPPED)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun shutdownTunnelOnly() {
        try {
            engine?.stop()
        } catch (_: Exception) {}
        engine = null
        try {
            tun?.close()
        } catch (_: Exception) {}
        tun = null
    }

    override fun onRevoke() {
        // User disabled the VPN in system settings — clean up, go failed.
        setState(State.FAILED, "revoked by system")
        shutdownTunnelOnly()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        shutdownTunnelOnly()
        super.onDestroy()
    }

    // --------------------------------------------------------------- notify

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "Atlanhix VPN", NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun updateNotification() {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFY_ID, buildNotification())
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
        val text = when (state) {
            State.IDLE, State.STOPPED -> "Stopped"
            State.REQUESTING_PERMISSION -> "Waiting for VPN permission"
            State.PREPARING -> "Preparing…"
            State.STARTING -> "Starting engine…"
            State.VALIDATING -> "Validating tunnel…"
            State.CONNECTED -> "Connected"
            State.RECONNECTING -> "Reconnecting…"
            State.STOPPING -> "Stopping…"
            State.FAILED -> "Failed: ${stateDetail ?: "unknown"}"
        }
        return builder
            .setContentTitle("Atlanhix")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_vpn_ic)
            .setContentIntent(pi)
            .setOngoing(state != State.STOPPED)
            .build()
    }

    enum class State {
        IDLE, REQUESTING_PERMISSION, PREPARING, STARTING, VALIDATING,
        CONNECTED, RECONNECTING, STOPPING, STOPPED, FAILED
    }

    companion object {
        const val CHANNEL_ID = "atlanhix_vpn"
        const val NOTIFY_ID = 0x4154 // 'AT'

        // Static mirror — the platform channel answers from the UI process
        // without binding the service first. Config is stashed by the
        // channel right before startService() (same process).
        @Volatile var state: State = State.IDLE
        @Volatile var stateDetail: String? = null
        @Volatile var pendingConfig: JSONObject? = null

        object Action {
            const val START = "com.example.nexus.vpn.START"
            const val STOP = "com.example.nexus.vpn.STOP"
        }
    }
}

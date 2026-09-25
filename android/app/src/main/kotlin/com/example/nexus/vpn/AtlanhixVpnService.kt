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
import io.nekohasekai.libbox.TunOptions
import org.json.JSONObject
import com.example.nexus.R
import java.io.File
import java.net.InetAddress

/**
 * Atlanhix Android VPN transport (v0.4.1).
 *
 * Owns the VpnService permission lifecycle, the TUN Builder and per-app
 * lists; the ENGINE is libbox (real sing-box v1.14.0, see LibboxEngine).
 *
 * v0.4.1 flow (§2): the service no longer opens the TUN fd itself first.
 * Instead: Dart sends the generated sing-box config → LibboxEngine
 * startOrReloadService → libbox's tun inbound calls [openTunForBox] →
 * THIS service applies MTU/addresses/DNS/routes/per-app lists from the
 * TunOptions (derived from the generated config — one source of truth) →
 * establish() → fd handed to libbox. State advances only on real events;
 * Dart flips to CONNECTED only after a real probe through the tunnel (§5).
 */
class AtlanhixVpnService : VpnService(), AtlanhixPlatformInterface {


    private var tun: ParcelFileDescriptor? = null
    private var engine: LibboxEngine? = null

    override fun context(): android.content.Context = this

    private fun setState(s: State, detail: String? = null, code: String? = null) {
        state = s
        stateDetail = detail
        errorCode = code ?: if (s == State.FAILED) errorCode else null
        // v0.4.1: every transition is logged for device E2E observability.
        val d = if (detail != null && detail.isNotEmpty()) " detail=" + detail else ""
        val cd = if (code != null) " code=" + code else ""
        android.util.Log.i("AtlanhixVpn", "state=" + s.name + d + cd)
        updateNotification()
    }

    override fun onCreate() {
        appContext = applicationContext
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                shutdown()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                // Foreground first — Android requires it before long work.
                startForeground(NOTIFY_ID, buildNotification())
                // Adopt THIS connect's generation atomically with the first
                // state it produces (main-thread serialization), then run
                // the state machine below.
                generation = pendingConfig?.optString("generation", null)
                    ?.takeIf { it.isNotEmpty() }
                val s = state
                if (s == State.VALIDATING) {
                    // Reconnect intent while a half-open session is still
                    // probing (device 2026-09-15: slow provider quarantine
                    // kept VALIDATING for 15s, and every fresh tap died with
                    // "session already active"). The Dart side already gave
                    // up on that attempt — replace it: tear down, rebuild.
                    setState(State.RECONNECTING)
                    shutdownTunnelOnly()
                    startTunnel()
                    return START_STICKY
                }
                if (s != State.IDLE && s != State.STOPPED && s != State.FAILED &&
                    s != State.REVOKED) {
                    // REVOKED (system killed the tunnel earlier) must NOT
                    // wedge future connects — device 2026-09-15: after one
                    // failed xhttp attempt every later tap died with
                    // "start while REVOKED — session already active",
                    // including previously-working Shadowsocks nodes.
                    setState(State.FAILED, "start while $s — session already active", ERR_SERVICE_START_FAILED)
                    return START_NOT_STICKY
                }
                setState(State.PREPARING)
                startTunnel()
            }
            else -> {
                // System restart delivery: rebuild the tunnel if we were up.
                // v0.4.9 §user-fix: null intent + no pendingConfig = the OS
                // redelivered a sticky restart for a session whose owner is
                // gone (app closed) — do NOT rebuild; answer STOPPED so the
                // notification never resurrects on its own.
                if (state == State.VALIDATING || state == State.CONNECTED) {
                    setState(State.RECONNECTING)
                    shutdownTunnelOnly()
                    startTunnel()
                } else if (intent == null && AtlanhixVpnService.pendingConfig == null) {
                    AtlanhixTrace.log("STICKY_RESTART ignored (no owner)")
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
        }
        return START_STICKY
    }

    // ------------------------------------------------------------------ TUN

    private fun startTunnel() {
        // Fresh trace id per connect intent + open the engine log BEFORE any
        // config capture, so CONFIG_SUMMARY / FINAL_CONFIG actually land in
        // the file (open() truncates — it must precede every append).
        AtlanhixTrace.new()
        EngineLogFile.open(this, AtlanhixTrace.id)
        AtlanhixTrace.log("CONNECT_REQUEST (native startTunnel)")
        val config = pendingConfig
        if (config == null) {
            AtlanhixTrace.err("FAILED stage=startTunnel error=no config handoff received")
            setState(State.FAILED, "no config handoff received", ERR_CONFIG_INVALID)
            return
        }
        val configJson = config.optString("configJson", "")
        if (configJson.isBlank()) {
            AtlanhixTrace.err("FAILED stage=startTunnel error=empty engine config")
            setState(State.FAILED, "empty engine config", ERR_CONFIG_INVALID)
            return
        }
        AtlanhixTrace.log("CONFIG_RECEIVED bytes=${configJson.length}")
        // §8 smoke diagnostics: sing-box writes its OWN log (startup lines,
        // dial errors, fatals) directly to a file we can read over adb —
        // independent of the command-client stream state.
        runCatching {
            val sbLog = File(getExternalFilesDir(null), "singbox.log")
            if (sbLog.exists()) sbLog.delete()
        }
        logConfigSummary(configJson)
        // §7: capture the FULL final config (post all Dart transformations) to
        // the engine log for exact-field validation. Redaction applies (§1).
        EngineLogFile.append("FINAL_CONFIG_BEGIN")
        EngineLogFile.append(AtlanhixRedact.apply(configJson))
        EngineLogFile.append("FINAL_CONFIG_END")
        setState(State.STARTING)
        // v0.4.9 §user-fix: the handoff is consumed here. Keeping it made a
        // system START_STICKY redelivery (after the process was killed with
        // the tunnel down) REBUILD a dead session — resurrecting the
        // "atlanhix core" notification after the user closed the app.
        pendingConfig = null
        val include = stringList(config, "includeApps")
        val exclude = stringList(config, "excludeApps")
        val eng = engine ?: LibboxEngine(this, this).also { engine = it }
        eng.start(configJson, include, exclude, engineEvents)
        // State advances ONLY via engineEvents + Dart-side probe (§5).
    }

    /**
     * Structured summary of the FINAL config handed to libbox (§7): inbound
     * types/ports, outbound tags/types, selector members. Values are type/
     * tag-level only — no servers, no ports of upstreams, no secrets.
     */
    private fun logConfigSummary(configJson: String) {
        try {
            val root = JSONObject(configJson)
            val sb = StringBuilder("CONFIG_SUMMARY")
            val inbounds = root.optJSONArray("inbounds")
            if (inbounds != null) {
                sb.append(" inbounds=[")
                for (i in 0 until inbounds.length()) {
                    val io = inbounds.getJSONObject(i)
                    sb.append(io.optString("type")).append(':').append(io.optString("tag"))
                    if (io.has("listen_port")) sb.append(':').append(io.optInt("listen_port"))
                    sb.append(' ')
                }
                sb.append(']')
            }
            val outbounds = root.optJSONArray("outbounds")
            if (outbounds != null) {
                sb.append(" outbounds=[")
                for (i in 0 until outbounds.length()) {
                    val o = outbounds.getJSONObject(i)
                    sb.append(o.optString("tag")).append('(').append(o.optString("type")).append(')')
                    val sel = o.optJSONArray("outbounds")
                    if (sel != null) {
                        sb.append('{')
                        for (k in 0 until sel.length()) sb.append(sel.optString(k)).append(',')
                        sb.append('}')
                    }
                    sb.append(' ')
                }
                sb.append(']')
            }
            val dns = root.optJSONObject("dns")
            if (dns != null) {
                val servers = dns.optJSONArray("servers")
                if (servers != null) {
                    sb.append(" dns_servers=")
                    for (i in 0 until servers.length()) {
                        val s = servers.opt(i)
                        // server entries may be strings or objects with address
                        val addr = when (s) {
                            is String -> s
                            is JSONObject -> s.optString("address", "?")
                            else -> "?"
                        }
                        sb.append(AtlanhixRedact.apply(addr)).append(',')
                    }
                }
            }
            val route = root.optJSONObject("route")
            if (route != null) {
                sb.append(" route_rules=${route.optJSONArray("rules")?.length() ?: 0}")
                val finalTag = route.optString("final", "")
                if (finalTag.isNotEmpty()) sb.append(" final=").append(finalTag)
            }
            val summary = AtlanhixRedact.apply(sb.toString())
            AtlanhixTrace.log(summary)
            EngineLogFile.append(summary)
        } catch (e: Exception) {
            AtlanhixTrace.warn("CONFIG_SUMMARY_FAILED: ${e.javaClass.simpleName}")
        }
    }

    private fun stringList(config: JSONObject, key: String): List<String> {
        val arr = config.optJSONArray(key) ?: return emptyList()
        return (0 until arr.length()).mapNotNull { i ->
            runCatching { arr.getString(i) }.getOrNull()
        }
    }

    // ------------------------------------------------ libbox openTun callback

    /**
     * libbox tun inbound init (real TUN creation point, §13/§16):
     * TunOptions carries what the GENERATED CONFIG decided (mtu, addresses,
     * dns, routes, strict route) plus the per-app override lists. The
     * Builder mirrors SFA's VPNService.openTun.
     */
    override fun openTunForBox(options: TunOptions): Int {
        AtlanhixTrace.log(
            "TUN_REQUESTED mtu=${options.mtu} autoRoute=${options.autoRoute}" +
                " strictRoute=${options.strictRoute}"
        )
        if (prepare(this) != null) {
            AtlanhixTrace.err("FAILED stage=openTun error=VPN permission missing at TUN creation")
            setState(State.FAILED, "VPN permission missing at TUN creation", ERR_PERMISSION_DENIED)
            error("android: missing vpn permission")
        }
        try {
            AtlanhixTrace.log("TUN_BUILDER_CONFIGURING")
            val b = Builder()
                .setSession("Atlanhix")
                .setMtu(options.mtu)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                b.setMetered(false)
            }

            val inet4 = options.inet4Address
            while (inet4.hasNext()) {
                val p = inet4.next()
                b.addAddress(p.address(), p.prefix())
            }
            val inet6 = options.inet6Address
            while (inet6.hasNext()) {
                val p = inet6.next()
                b.addAddress(p.address(), p.prefix())
            }

            if (options.autoRoute) {
                val dns = options.dnsServerAddress
                while (dns.hasNext()) {
                    b.addDnsServer(dns.next())
                }

                // v0.4.1 §23: routes come from the generated config.
                // API 33+: explicit route-address + exclude support.
                // Older: libbox's pre-computed route ranges (same as SFA).
                // NOTE: the IpPrefix-typed addRoute/excludeRoute overloads are
                // API 33+; on lower API levels we fall back to route ranges.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val r4 = options.inet4RouteAddress
                    var has4 = false
                    while (r4.hasNext()) {
                        val p = r4.next()
                        b.addRoute(p.address(), p.prefix())
                        has4 = true
                    }
                    if (!has4 && options.inet4Address.hasNext()) b.addRoute("0.0.0.0", 0)
                    val r6 = options.inet6RouteAddress
                    var has6 = false
                    while (r6.hasNext()) {
                        val p = r6.next()
                        b.addRoute(p.address(), p.prefix())
                        has6 = true
                    }
                    if (!has6 && options.inet6Address.hasNext()) b.addRoute("::", 0)
                    // excludeRoute(IpPrefix) is API 33+; address()/prefix() come
                    // from libbox as strings, so build java.net.InetAddress.
                    val e4 = options.inet4RouteExcludeAddress
                    while (e4.hasNext()) {
                        val p = e4.next()
                        b.excludeRoute(ipPrefixOf(p.address(), p.prefix()))
                    }
                    val e6 = options.inet6RouteExcludeAddress
                    while (e6.hasNext()) {
                        val p = e6.next()
                        b.excludeRoute(ipPrefixOf(p.address(), p.prefix()))
                    }
                } else {
                    val r4 = options.inet4RouteRange
                    while (r4.hasNext()) { val p = r4.next(); b.addRoute(p.address(), p.prefix()) }
                    val r6 = options.inet6RouteRange
                    while (r6.hasNext()) { val p = r6.next(); b.addRoute(p.address(), p.prefix()) }
                }

                // §13/§16 per-app routing — REAL Android bypass/allow:
                // include-list (addAllowedApplication) wins over exclude-list
                // (addDisallowedApplication) exactly as in SFA.
                val include = options.includePackage
                while (include.hasNext()) {
                    try {
                        b.addAllowedApplication(include.next())
                    } catch (e: PackageManager.NameNotFoundException) {
                        android.util.Log.w("AtlanhixVpn", "addAllowedApplication failed: ${e.message}")
                    }
                }
                val exclude = options.excludePackage
                while (exclude.hasNext()) {
                    try {
                        b.addDisallowedApplication(exclude.next())
                    } catch (e: PackageManager.NameNotFoundException) {
                        android.util.Log.w("AtlanhixVpn", "addDisallowedApplication failed: ${e.message}")
                    }
                }
            }

            // setBlocking requires API 29+ (guard for lower API levels).
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                b.setBlocking(false)
            }
            AtlanhixTrace.log("TUN_ESTABLISHING")
            val fd = b.establish()
            if (fd == null) {
                AtlanhixTrace.err("FAILED stage=openTun error=establish() returned null — permission missing or revoked")
                setState(State.FAILED, "establish() returned null — permission missing or revoked", ERR_PERMISSION_DENIED)
                error("android: the application is not prepared or is revoked")
            }
            tun = fd
            AtlanhixTrace.log("TUN_ESTABLISHED fd=${fd!!.fd}")
            AtlanhixTrace.log("TUN_FD_TRANSFERRED to libbox exactly-once")
            setState(State.VALIDATING)
            return fd.fd
        } catch (e: Exception) {
            AtlanhixTrace.err("FAILED stage=openTun error=tun setup: ${e.javaClass.simpleName}: ${AtlanhixRedact.apply(e.message ?: "")}")
            setState(State.FAILED, "tun setup failed: ${e.message}", ERR_TUN_CREATE_FAILED)
            throw e
        }
    }

    // SFA-style required PlatformInterface override (openTun is the Go-side
    // entry; we route it to openTunForBox).
    override fun openTun(options: TunOptions): Int = openTunForBox(options)

    // ------------------------------------------------------- engine events

    private val engineEvents = object : EngineEvents {
        override fun onStarted() {
            // TUN is up and the Box is running; the Dart probe decides
            // CONNECTED (§5) — the service stays in VALIDATING until then.
            setState(State.VALIDATING)
        }
        override fun onFailed(reason: String) {
            setState(State.FAILED, reason, ERR_ENGINE_START_FAILED)
            shutdownTunnelOnly()
        }
        override fun onCrashed(reason: String) {
            setState(State.RECONNECTING)
            shutdownTunnelOnly()
            startTunnel()
        }
        override fun onStopped() {
            // Normal stop is handled by shutdown(); a surprise stop lands
            // back at STOPPED only if we were mid-session.
            if (state == State.VALIDATING || state == State.CONNECTED || state == State.RECONNECTING) {
                setState(State.STOPPED)
            }
        }
    }

    // ------------------------------------------------------------- shutdown

    private fun shutdown() {
        AtlanhixTrace.log("SHUTDOWN_REQUESTED")
        setState(State.STOPPING)
        shutdownTunnelOnly()
        setState(State.STOPPED)
        AtlanhixTrace.log("STOPPED clean")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun shutdownTunnelOnly() {
        AtlanhixTraffic.reset()
        try {
            engine?.stop()
        } catch (_: Exception) {}
        engine = null
        val hadTun = tun != null
        try {
            tun?.close()
        } catch (_: Exception) {}
        tun = null
        if (hadTun) AtlanhixTrace.log("TUN_CLOSED (fd released exactly-once)")
    }

    override fun onRevoke() {
        // §4: user disabled the VPN in system settings — explicit REVOKED
        // transition (never FAILED; the UI distinguishes denial vs revoke).
        setState(State.REVOKED, "revoked by system", ERR_VPN_REVOKED)
        shutdownTunnelOnly()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        shutdownTunnelOnly()
        // v0.4.9 §user-fix ("atlanhix core even after closing the app"):
        // whatever path destroyed the service, the notification must go —
        // a sticky foreground notification on a dead tunnel is a lie.
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {}
        super.onDestroy()
    }

    // v0.4.9 §user-fix: swiping the app away (onTaskRemoved) must tear the
    // tunnel AND the notification down. Until now the service (START_STICKY)
    // survived as an orphaned foreground service with a live pill — the
    // exact "notification stays even after I close the app" report.
    override fun onTaskRemoved(rootIntent: Intent?) {
        AtlanhixTrace.log("TASK_REMOVED — tearing session down")
        setState(State.STOPPING)
        shutdownTunnelOnly()
        setState(State.STOPPED)
        AtlanhixTrace.log("STOPPED (task removed)")
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {}
        stopSelf()
        super.onTaskRemoved(rootIntent)
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
            State.FAILED -> "Failed"
            State.REVOKED -> "VPN permission revoked"
        }
        return builder
            .setContentTitle("Atlanhix")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_vpn_status)
            .setContentIntent(pi)
            .setOngoing(state != State.STOPPED)
            .build()
    }

    private fun ipPrefixOf(address: String, prefix: Int): android.net.IpPrefix {
        val addr = InetAddress.getByName(address)
        return if (addr is java.net.Inet4Address) {
            android.net.IpPrefix(addr, prefix)
        } else {
            android.net.IpPrefix(addr, prefix)
        }
    }

    enum class State {
        IDLE, REQUESTING_PERMISSION, PREPARING, STARTING, VALIDATING,
        CONNECTED, RECONNECTING, STOPPING, STOPPED, FAILED, REVOKED
    }

    companion object {
        const val CHANNEL_ID = "atlanhix_vpn"
        const val NOTIFY_ID = 0x4154 // 'AT'
        @JvmStatic lateinit var appContext: android.content.Context
        const val ACTION_START = "com.example.nexus.vpn.START"
        const val ACTION_STOP = "com.example.nexus.vpn.STOP"

        // Static mirror — the platform channel answers from the UI process
        // without binding the service first. Config is stashed by the
        // channel right before startService() (same process).
        @Volatile var state: State = State.IDLE
        @Volatile var stateDetail: String? = null
        @Volatile var errorCode: String? = null
        @Volatile var pendingConfig: JSONObject? = null

        // Pipeline-audit fix #3 (device 2026-09-15): Dart stamps a
        // per-connect `generation` into the start payload; it is echoed in
        // every state response so a poll that lands BEFORE onStartCommand
        // runs (the intent is queued on the main looper) is recognized as
        // the PREVIOUS session's state and skipped — that race made a
        // stale CONNECTED read "succeed" on a dying tunnel and a stale
        // FAILED read abort (then stop) a fresh session mid-boot.
        @Volatile var generation: String? = null

        const val ERR_PERMISSION_DENIED = "VPN_PERMISSION_DENIED"
        const val ERR_TUN_CREATE_FAILED = "TUN_CREATE_FAILED"
        const val ERR_ENGINE_START_FAILED = "ENGINE_START_FAILED"
        const val ERR_CONFIG_INVALID = "CONFIG_INVALID"
        const val ERR_VPN_REVOKED = "VPN_REVOKED"
        const val ERR_SERVICE_START_FAILED = "SERVICE_START_FAILED"
    }
}

package com.example.nexus.vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Process
import android.system.OsConstants
import java.net.InetAddress
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.io.File
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.NetworkInterface

/**
 * v0.4.1 — the REAL tunneling engine: sing-box libbox (same engine as SFA),
 * compiled from sing-box v1.14.0 source for arm64-v8a and bundled as
 * android/app/libs/libbox.aar.
 *
 * Architecture (mirrors sing-box-for-android):
 *   AtlanhixVpnService (VpnService, implements [AtlanhixPlatformInterface])
 *   └─ LibboxEngine
 *       ├─ CommandServer(handler, platformInterface)   ← control plane
 *       │    └─ startOrReloadService(configJson, override)
 *       │         └─ Box starts; tun inbound calls platformInterface.openTun()
 *       │            → the SERVICE establishes the Builder and returns the fd
 *       │         └─ sing-box then routes traffic through that fd
 *       └─ CommandClient(clientHandler, options)       ← observability plane
 *            └─ libbox pushes sing-box log lines + status into writeLogs /
 *               writeStatus; every line is redacted and mirrored to logcat
 *               (tag ATX-ENGINE) and to an on-device log file.
 *
 * Config is generated Dart-side (RoutingCompiler + SingBoxConfigGenerator)
 * from the REAL settings; libbox parses/validates it — an invalid config
 * throws out of startOrReloadService and surfaces as ENGINE_START_FAILED.
 *
 * TRACE (v0.4.1 blocker task): every stage logs "[ATX-CONNECT-xxxx]" via
 * [AtlanhixTrace] so the full pipeline is reconstructable from logcat:
 *   CONNECT_REQUEST → CONFIG_RECEIVED → LIBBOX_INITIALIZING →
 *   COMMAND_SERVER_READY → CONFIG_ACCEPTED → TUN_REQUESTED → TUN_ESTABLISHED →
 *   LIBBOX_STARTED → ENGINE_LOGS → status/probe → CONNECTED | FAILED(stage).
 */
/** Latest engine status counters (libbox pushes these every second). */
object AtlanhixTraffic {
    @Volatile var up = 0L
    @Volatile var down = 0L
    @Volatile var conns = 0L
    fun reset() {
        up = 0
        down = 0
        conns = 0
    }
}

object AtlanhixTrace {
    @Volatile var id: String = "ATX-CONNECT-0000"
    fun new(): String {
        id = "ATX-CONNECT-" + java.util.UUID.randomUUID().toString().substring(0, 4)
        return id
    }
    fun log(message: String): Unit { android.util.Log.i("ATX", "[$id] $message") }
    fun warn(message: String): Unit { android.util.Log.w("ATX", "[$id] $message") }
    fun err(message: String): Unit { android.util.Log.e("ATX", "[$id] $message") }
}

/** Redacts secrets BEFORE anything is logged or written (§42 parity with Dart). */
object AtlanhixRedact {
    private val patterns = listOf(
        // uuid-shaped ids (vmess/vless/tuic users)
        Regex("\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b"),
        // credential-ish json keys ("password": "x", "privateKey": "x", …)
        Regex("(\"(?:password|privateKey|secret|token|auth_str|obfsPassword|uuid)\"\\s*:\\s*\")([^\"]*)(\")"),
        // userinfo in URLs  scheme://user:pass@host
        Regex("(?<=://)[^:@/\\s]+:[^@/\\s]+@"),
        // subscription urls carrying tokens
        Regex("https?://\\S+/(?:sub|api/v1/client/subscribe)\\S*"),
        // query params  password=… token=…
        Regex("\\b(?:password|pass|secret|token|key)=[^\\s&;]+"),
    )

    fun apply(message: String): String {
        var m = message
        for (p in patterns) {
            m = p.replace(m) { mr ->
                val g = mr.value
                when {
                    // json key form: keep the key, mask the value
                    g.startsWith("\"") && mr.groups.size == 4 ->
                        mr.groupValues[1] + "***" + mr.groupValues[3]
                    g.length <= 6 -> "***"
                    else -> g.substring(0, 3) + "***" + g.substring(g.length - 2)
                }
            }
        }
        return m
    }
}

/**
 * On-device engine log ring (postmortem when logcat is filtered by MIUI).
 * Truncated on each service start; readable via run-as from the host.
 */
object EngineLogFile {
    private var writer: java.io.FileWriter? = null
    private var file: File? = null

    @Synchronized
    fun open(context: Context, traceId: String) {
        close()
        val dir = File(context.getExternalFilesDir(null), "logs").apply { mkdirs() }
        file = File(dir, "engine.log").apply { writeText("") }
        writer = java.io.FileWriter(file, false)
        append("=== session $traceId ===")
    }

    @Synchronized
    fun append(line: String) {
        val w = writer ?: return
        try {
            w.append(java.text.SimpleDateFormat("MM-dd HH:mm:ss.SSS", java.util.Locale.US)
                .format(java.util.Date())).append(' ').appendLine(line)
            w.flush()
        } catch (_: Exception) {}
    }

    @Synchronized
    fun close() {
        try { writer?.flush(); writer?.close() } catch (_: Exception) {}
        writer = null
    }
}

object LibboxSetup {
    @Volatile private var initialized = false

    /** One-time global libbox init (paths, log limits, version metadata). */
    fun initialize(context: Context) {
        initializeWithPaths(context, null)
    }

    /**
     * v0.4.9 §cache-fix: libbox's setup is GLOBAL per process (base/working
     * dirs) and sing-box derives its default cache.db path from the working
     * dir. The VPN service and the TRANSIENT probe engine share the main
     * process — two Boxes booting with the same workingDir raced over
     * cache.db and the tunnel start died with `initialize cache-file:
     * timeout` (device log 2026-09-25 19:57). The probe passes its own
     * working dir so its cache file lives in a DIFFERENT directory and
     * never contends with the service's. First setup wins for the process
     * (the service initializes before the first connect — the probe only
     * runs pre-connect), which is why the probe must carry its own paths.
     */
    fun initializeWithPaths(context: Context, workingPathOverride: String?) {
        if (initialized) return
        synchronized(this) {
            if (initialized) return
            val baseDir = context.filesDir
            val workingDir = workingPathOverride?.let { File(it) }
                ?: context.getExternalFilesDir(null)
                ?: baseDir
            val tempDir = context.cacheDir
            baseDir.mkdirs(); workingDir.mkdirs(); tempDir.mkdirs()
            val options = SetupOptions().also {
                it.basePath = baseDir.path
                it.workingPath = workingDir.path
                it.tempPath = tempDir.path
                it.logMaxLines = 3000
                it.debug = false
                it.crashReportSource = "Atlanhix"
                it.appVersion = "8"
                it.appMarketingVersion = "0.4.2"
            }
            Libbox.setup(options)
            initialized = true
        }
    }
}

class LibboxEngine(
    private val context: Context,
    private val platformInterface: AtlanhixPlatformInterface,
) {
    private var commandServer: CommandServer? = null
    private var commandClient: CommandClient? = null
    @Volatile var isRunning = false
        private set

    /**
     * Starts the engine. include/exclude packages are applied as the
     * OverrideOptions per-app lists (v0.4.1 §13/§16) — when include is
     * non-empty ONLY those apps ride the VPN; otherwise exclude lists the
     * DIRECT apps that bypass it.
     *
     * [workingPathOverride] (v0.4.9 §cache-fix): engine-private libbox
     * working dir — used by the TRANSIENT probe engine so its cache.db
     * never contends with the service's (both Boxes share the process).
     * Ignored when another engine already initialized libbox in this
     * process (first setup wins — documented in [LibboxSetup]).
     */
    fun start(
        configJson: String,
        includePackages: List<String>,
        excludePackages: List<String>,
        listener: EngineEvents,
        workingPathOverride: String? = null,
    ) {
        AtlanhixTrace.log("LIBBOX_INITIALIZING")
        // NOTE: the engine log file is opened by the SERVICE (startTunnel)
        // BEFORE the config capture — opening it here a second time would
        // truncate away CONFIG_SUMMARY / FINAL_CONFIG (observed on device).
        LibboxSetup.initializeWithPaths(context, workingPathOverride)
        try {
            val server = CommandServer(Handler(listener), platformInterface)
            server.start()
            commandServer = server
            AtlanhixTrace.log("COMMAND_SERVER_READY")

            // Observability plane: subscribe to sing-box's own logs + status.
            // This is where the REAL engine errors surface in libbox v1.14
            // (the CommandServerHandler has no error callback by design).
            try {
                val opts = CommandClientOptions().apply {
                    addCommand(Libbox.CommandLog)
                    addCommand(Libbox.CommandStatus)
                    addCommand(Libbox.CommandGroup)
                    addCommand(Libbox.CommandOutbounds)
                    statusInterval = 1_000_000_000L // 1s (time.Duration ns)
                }
                commandClient = CommandClient(EngineLogClient(), opts)
                // SFA parity: the client must CONNECT to the command server
                // before log/status streams flow. Without connect() the
                // engine's own log lines (incl. fatals) never reach us —
                // this was the instrumentation gap that hid the failure.
                commandClient?.connect()
                AtlanhixTrace.log("ENGINE_LOG_CLIENT_READY")
            } catch (e: Exception) {
                AtlanhixTrace.warn("ENGINE_LOG_CLIENT_FAILED: ${AtlanhixRedact.apply(e.message ?: e.javaClass.simpleName)}")
            }

            val override = OverrideOptions().apply {
                if (includePackages.isNotEmpty()) {
                    includePackage = StringArray(includePackages.toList())
                }
                if (excludePackages.isNotEmpty()) {
                    excludePackage = StringArray(excludePackages.toList())
                }
            }
            AtlanhixTrace.log(
                "CONFIG_ACCEPTED bytes=${configJson.length} include=${includePackages.size} exclude=${excludePackages.size}"
            )
            // Parses + validates + starts the Box; throws on invalid config
            // (surfaces as ENGINE_START_FAILED, never a fake start). The
            // service flips to CONNECTED only after the Dart-side probe.
            server.startOrReloadService(configJson, override)
            isRunning = true
            AtlanhixTrace.log("LIBBOX_STARTED")
            // NOW the Go consumer is installed — safe to push updates.
            DefaultInterfaceMonitor.activate(context)
        } catch (e: Exception) {
            isRunning = false
            AtlanhixTrace.err("LIBBOX_START_FAILED: ${e.javaClass.simpleName}: ${AtlanhixRedact.apply(e.message ?: "")}")
            EngineLogFile.append("LIBBOX_START_FAILED: ${e.javaClass.simpleName}: ${AtlanhixRedact.apply(e.message ?: "")}")
            EngineLogFile.close()
            stopQuietly()
            listener.onFailed("libbox: ${AtlanhixRedact.apply(e.message ?: e.javaClass.simpleName)}")
        }
    }

    fun stop() {
        isRunning = false
        stopQuietly()
    }

    private fun stopQuietly() {
        try {
            commandClient?.serviceClose()
        } catch (_: Exception) {}
        commandClient = null
        try {
            commandServer?.closeService()
        } catch (_: Exception) {}
        try {
            commandServer?.close()
        } catch (_: Exception) {}
        commandServer = null
        DefaultInterfaceMonitor.stop(context)
        EngineLogFile.append("ENGINE_STOPPED")
        EngineLogFile.close()
    }

    private inner class Handler(private val listener: EngineEvents) : CommandServerHandler {
        override fun serviceStop() {
            AtlanhixTrace.log("CALLBACK serviceStop")
            EngineLogFile.append("callback: serviceStop")
            listener.onStopped()
        }

        override fun serviceReload() {
            AtlanhixTrace.log("CALLBACK serviceReload")
            // Hot reload not wired in v0.4.1; settings apply on next connect.
        }

        override fun getSystemProxyStatus(): SystemProxyStatus {
            AtlanhixTrace.log("CALLBACK getSystemProxyStatus")
            return SystemProxyStatus().apply { available = false; enabled = false }
        }

        override fun setSystemProxyEnabled(enabled: Boolean) {
            AtlanhixTrace.log("CALLBACK setSystemProxyEnabled=$enabled")
        }

        override fun triggerNativeCrash() {
            AtlanhixTrace.warn("CALLBACK triggerNativeCrash (ignored)")
        }

        override fun writeDebugMessage(message: String) {
            val red = AtlanhixRedact.apply(message)
            AtlanhixTrace.log("CALLBACK writeDebugMessage: $red")
            EngineLogFile.append("debug: $red")
        }

        override fun connectSSHAgent(): Int {
            AtlanhixTrace.log("CALLBACK connectSSHAgent -> -1")
            return -1
        }
    }

    /**
     * Receives everything sing-box itself logs + periodic status. This is
     * the ONLY channel engine-internal errors reach us through in libbox
     * v1.14 — without it the failure during VALIDATING→STOPPING is mute.
     */
    private inner class EngineLogClient : CommandClientHandler {
        private var lastUplink = 0L
        private var lastDownlink = 0L

        override fun writeLogs(logs: io.nekohasekai.libbox.LogIterator) {
            while (logs.hasNext()) {
                val e = logs.next()
                val red = AtlanhixRedact.apply(e.message)
                val lvl = e.level
                when {
                    lvl >= 4 -> AtlanhixTrace.err("SINGBOX: $red")   // error/fatal
                    lvl >= 3 -> AtlanhixTrace.warn("SINGBOX: $red")  // warn
                    else -> AtlanhixTrace.log("SINGBOX: $red")       // info/trace
                }
                EngineLogFile.append("singbox: $red")
            }
        }

        override fun writeStatus(status: io.nekohasekai.libbox.StatusMessage) {
            val up = status.uplink
            val down = status.downlink
            val connectionsIn = status.connectionsIn
            val connectionsOut = status.connectionsOut
            // Log deltas only — real-traffic evidence without spam (§9).
            // v0.4.4 §user-2: publish the engine's REAL counters so the
            // channel's state() can surface them to Dart every poll — the
            // dashboard DOWNLOAD/UPLOAD/speed graph finally move on device
            // (previously the desktop Clash-API polling was all there was,
            // and libbox never had it — the read was always null/0).
            AtlanhixTraffic.up = up
            AtlanhixTraffic.down = down
            AtlanhixTraffic.conns =
                (connectionsIn + connectionsOut).toLong()
            if (up != lastUplink || down != lastDownlink) {
                lastUplink = up
                lastDownlink = down
            }
        }

        override fun writeOutbounds(outbounds: io.nekohasekai.libbox.OutboundGroupItemIterator) {
            val tags = StringBuilder()
            while (outbounds.hasNext()) {
                val o = outbounds.next()
                tags.append(o.tag).append('(').append(o.type).append(") ")
            }
            AtlanhixTrace.log("OUTBOUNDS: $tags")
            EngineLogFile.append("outbounds: $tags")
        }

        override fun writeGroups(groups: io.nekohasekai.libbox.OutboundGroupIterator) {
            while (groups.hasNext()) {
                val g = groups.next()
                AtlanhixTrace.log("GROUP: ${g.tag} selected=${g.selected}")
            }
        }

        override fun connected() = AtlanhixTrace.log("SINGBOX command-client connected")
        override fun disconnected(message: String) =
            AtlanhixTrace.warn("SINGBOX command-client disconnected: ${AtlanhixRedact.apply(message)}")

        override fun clearLogs() {}
        override fun setDefaultLogLevel(level: Int) {}
        override fun initializeClashMode(tags: StringIterator, current: String) {}
        override fun updateClashMode(tag: String) {}
        override fun writeConnectionEvents(events: io.nekohasekai.libbox.ConnectionEvents) {}
        // lx-fork addition (v1.14.1-lx: DNS observability stream). Atlanhix
        // does not surface per-query events yet — the no-op keeps the
        // CommandClient protocol contract satisfied against the forked AAR.
        override fun writeDNSQuery(query: io.nekohasekai.libbox.DnsQuery) {}
    }

}

/**
 * PlatformInterface libbox calls back into. Implemented by
 * AtlanhixVpnService so TUN/permission/notification glue stays in ONE place
 * while libbox owns the engine. Only the methods sing-box actually uses on
 * Android carry real logic; the rest are honest stubs (documented).
 */
class SystemDnsTransport : LocalDNSTransport {
    /** Name-lookup mode (raw=false): libbox routes A/AAAA queries to lookup(). */
    override fun raw(): Boolean = false

    override fun lookup(ctx: io.nekohasekai.libbox.ExchangeContext, network: String, domain: String) {
        // The platform resolver path: system DNS on MIUI points at 127.0.0.1
        // while the tunnel owns routing, so query netd directly on the best
        // PHYSICAL network (never tun0 — that hairpins back into the tunnel).
        val cm = AtlanhixVpnService.appContext.getSystemService(ConnectivityManager::class.java)
        val n = DefaultInterfaceMonitor.bestNonVpnNetwork(cm)
            ?: throw java.net.UnknownHostException("no physical network for DNS lookup")
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            val signal = android.os.CancellationSignal()
            val latch = java.util.concurrent.CountDownLatch(1)
            var addrs: List<java.net.InetAddress> = emptyList()
            var failure: Exception? = null
            android.net.DnsResolver.getInstance().query(
                n, domain, android.net.DnsResolver.FLAG_EMPTY,
                executor, signal,
                DnsAddrCallback({ res, _ -> addrs = res; latch.countDown() },
                               { e -> failure = e; latch.countDown() }))
            if (!latch.await(8, java.util.concurrent.TimeUnit.SECONDS)) {
                signal.cancel()
                throw java.net.UnknownHostException("dns lookup timeout (8s) $domain")
            }
            failure?.let { throw java.net.UnknownHostException("dns lookup failed: ${it.message}") }
            AtlanhixTrace.log("SYSTEM_DNS_LOOKUP $domain net=$network -> ${addrs.size} addrs")
            if (addrs.isEmpty()) throw java.net.UnknownHostException(domain)
            ctx.success(addrs.joinToString("\n") { it.hostAddress ?: "" })
        } finally {
            executor.shutdown()
        }
    }

    /** Raw exchange (unused while raw()=false; kept for interface completeness). */
    override fun exchange(ctx: io.nekohasekai.libbox.ExchangeContext, message: ByteArray) {
        ctx.errnoCode(1)
    }
}

private class DnsAddrCallback(
    private val onAns: (List<java.net.InetAddress>, Int) -> Unit,
    private val onErr: (Exception) -> Unit,
) : android.net.DnsResolver.Callback<MutableList<java.net.InetAddress>> {
    override fun onAnswer(res: MutableList<java.net.InetAddress>, rcode: Int) = onAns(res, rcode)
    override fun onError(e: android.net.DnsResolver.DnsException) = onErr(e)
}


interface AtlanhixPlatformInterface : PlatformInterface {
    /** libbox tun inbound init → establish() the Builder, return the fd. */
    fun openTunForBox(options: TunOptions): Int

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        // Protect the engine's own sockets from the VPN (upstream connections
        // must leave via the physical NIC, not the tunnel).
        android.util.Log.i("AtlanhixVpn", "AUTO_DETECT_PROTECT fd=$fd this=${this.javaClass.simpleName}")
        val vpn = this as? android.net.VpnService
        if (vpn != null) {
            vpn.protect(fd)
            android.util.Log.i("AtlanhixVpn", "AUTO_DETECT_PROTECT_OK fd=$fd")
            return
        }
        // v0.4.9 §probe-fix: the TRANSIENT probe engine runs inside the
        // plain app process — it is NOT a VpnService and there is nothing
        // to protect from. Its platform interface now declares
        // usePlatformAutoDetectInterfaceControl()=false, so libbox never
        // even calls this for the probe engine (the old bindProcessToNetwork
        // fallback here was dead code AND wrong: a process-wide network bind
        // leaks across engines sharing the process). The VPN service is the
        // only engine that protects sockets — exactly the branch above.
        android.util.Log.i(
            "AtlanhixVpn", "AUTO_DETECT_PROTECT_SKIP fd=$fd (no VPN on this engine)")
    }

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    override fun findConnectionOwner(
        ipProtocol: Int, sourceAddress: String, sourcePort: Int,
        destinationAddress: String, destinationPort: Int,
    ): ConnectionOwner {
        val cm = context().getSystemService(ConnectivityManager::class.java)
        val uid = try {
            cm.getConnectionOwnerUid(
                ipProtocol,
                InetSocketAddress(sourceAddress, sourcePort),
                InetSocketAddress(destinationAddress, destinationPort),
            )
        } catch (_: Exception) { Process.INVALID_UID }
        val owner = ConnectionOwner()
        if (uid == Process.INVALID_UID) {
            owner.userId = -1
            owner.userName = ""
            owner.setAndroidPackageNames(StringArray(emptyList<String>()))
            return owner
        }
        val packages = context().packageManager.getPackagesForUid(uid)
        owner.userId = uid
        owner.userName = packages?.firstOrNull() ?: ""
        owner.setAndroidPackageNames(StringArray((packages?.toList() ?: emptyList())))
        return owner
    }

    override fun startDefaultInterfaceMonitor(listener: io.nekohasekai.libbox.InterfaceUpdateListener) {
        // v0.4.1 ROOT-CAUSE FIX: libbox v1.14 with
        // usePlatformAutoDetectInterfaceControl=true learns the default
        // interface ONLY via InterfaceUpdateListener.updateDefaultInterface
        // — an empty stub made every outbound dial fail with "no available
        // network interface" (observed on device, sing-box log 2026-09-08).
        //
        // CRITICAL SEQUENCING: only STASH the listener here. Registering the
        // framework NetworkCallback during Box.New made the first
        // updateDefaultInterface land on the Go side before its consumer was
        // installed → native panic → SIGABRT in ConnectivityThr (tombstone
        // 2026-09-08 22:37, process died). SFA avoids this because it
        // registers callbacks in Application.onCreate, long before any
        // connect. We activate the monitor right after LIBBOX_STARTED.
        DefaultInterfaceMonitor.attach(listener)
    }

    override fun closeDefaultInterfaceMonitor(listener: io.nekohasekai.libbox.InterfaceUpdateListener) {
        DefaultInterfaceMonitor.stop(context())
    }

    private fun buildLibboxNetworkInterface(
        lp: android.net.LinkProperties,
        caps: NetworkCapabilities,
    ): io.nekohasekai.libbox.NetworkInterface? {
        val ni = io.nekohasekai.libbox.NetworkInterface()
        ni.name = lp.interfaceName
        val nif = NetworkInterface.getNetworkInterfaces().toList().find { it.name == ni.name }
        ni.dnsServer = StringArray(lp.dnsServers.mapNotNull { it.hostAddress?.substringBefore('%') })
        ni.gateway = StringArray(
            lp.routes.filter { it.destination.prefixLength == 0 }
                .mapNotNull { it.gateway }.filterNot { it.isAnyLocalAddress }
                .mapNotNull { it.hostAddress?.substringBefore('%') })
        ni.type = when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
            else -> Libbox.InterfaceTypeOther
        }
        if (nif != null) {
            ni.index = nif.index
            runCatching { ni.mtu = nif.mtu }
            var flags = 0
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                flags = flags or OsConstants.IFF_UP or OsConstants.IFF_RUNNING
            }
            if (nif.isLoopback) flags = flags or OsConstants.IFF_LOOPBACK
            if (nif.isPointToPoint) flags = flags or OsConstants.IFF_POINTOPOINT
            if (nif.supportsMulticast()) flags = flags or OsConstants.IFF_MULTICAST
            ni.flags = flags
            ni.addresses = StringArray(
                nif.interfaceAddresses.map { ia ->
                    "${ia.address.hostAddress?.substringBefore('%')}/${ia.networkPrefixLength}"
                })
            ni.metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        }
        return ni
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val cm = context().getSystemService(ConnectivityManager::class.java)
        val out = mutableListOf<io.nekohasekai.libbox.NetworkInterface>()
        var skipped = 0
        for (network in cm.allNetworks) {
            try {
                val lp = cm.getLinkProperties(network) ?: run { skipped++; continue }
                val caps = cm.getNetworkCapabilities(network) ?: run { skipped++; continue }
                val ni = buildLibboxNetworkInterface(lp, caps) ?: run { skipped++; continue }
                out.add(ni)
            } catch (e: Exception) {
                skipped++
                AtlanhixTrace.err("getInterfaces: per-network failure: ${e.message}")
            }
        }
        AtlanhixTrace.log("GET_INTERFACES count=${out.size} skipped=$skipped")
        return InterfaceArray(out.iterator())
    }

    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false
    override fun clearDNSCache() {}

    override fun readWIFIState(): WIFIState? = null // SSID rules not used in v0.4.1

    override fun localDNSTransport(): LocalDNSTransport? = SystemDnsTransport()

    /** System DNS via the Android platform (replaces the dead 127.0.0.1 fallback:
     *  Android has no /etc/resolv.conf, so libbox's local transport would dial
     *  loopback:53 — nothing listens there → every domain lookup fails). */


    override fun startNeighborMonitor(listener: io.nekohasekai.libbox.NeighborUpdateListener) {}
    override fun closeNeighborMonitor(listener: io.nekohasekai.libbox.NeighborUpdateListener) {}

    override fun usePlatformShell(): Boolean = false
    override fun checkPlatformShell() {}
    override fun openShellSession(
        user: io.nekohasekai.libbox.PlatformUser?, command: String?,
        environ: StringIterator?, term: String?, rows: Int, cols: Int,
    ): io.nekohasekai.libbox.ShellSession = throw UnsupportedOperationException("shell not supported")

    override fun readSystemSSHHostKey(): String = throw UnsupportedOperationException()
    override fun lookupSFTPServer(): String = throw UnsupportedOperationException()
    override fun lookupUser(username: String): io.nekohasekai.libbox.PlatformUser =
        throw UnsupportedOperationException()

    override fun tailscaleHostname(): String = Build.MODEL
    override fun usePlatformBridge(): Boolean = false
    override fun createBridge(options: io.nekohasekai.libbox.BridgeOptions?): io.nekohasekai.libbox.BridgeSession =
        throw UnsupportedOperationException()

    override fun sendNotification(notification: io.nekohasekai.libbox.Notification) {}
    override fun cancelNotification(identifier: String, typeID: Int) {}
    override fun registerMyInterface(name: String) {}

    fun context(): Context
}


/**
 * Default-network monitor for libbox v1.14 (InterfaceUpdateListener API:
 * updateDefaultInterface(name, index, isExpensive, isMetered)).
 *
 * Threading contract (hardened after on-device SIGABRT):
 *  - attach(): during Box.New — stores the listener ONLY.
 *  - activate(): after LIBBOX_STARTED — registers the ConnectivityManager
 *    callback and starts a bounded retry loop. All updateDefaultInterface
 *    calls are serialized on ONE executor thread (never concurrent).
 *  - stop(): unregisters everything.
 */
object DefaultInterfaceMonitor {
    @Volatile private var listener: io.nekohasekai.libbox.InterfaceUpdateListener? = null
    @Volatile private var callback: ConnectivityManager.NetworkCallback? = null
    private var executor: java.util.concurrent.ExecutorService? = null

    fun attach(l: io.nekohasekai.libbox.InterfaceUpdateListener) {
        listener = l
        AtlanhixTrace.log("INTERFACE_MONITOR listener attached")
    }

    @Synchronized
    fun activate(context: android.content.Context) {
        val l = listener ?: run {
            AtlanhixTrace.warn("INTERFACE_MONITOR activate: no listener")
            return
        }
        if (executor != null) return // already active
        try {
            val cm = context.getSystemService(ConnectivityManager::class.java)
            val request = android.net.NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: android.net.Network) {
                    submit(cm, l)
                }

                override fun onLinkPropertiesChanged(
                    network: android.net.Network,
                    lp: android.net.LinkProperties,
                ) {
                    submit(cm, l)
                }

                override fun onCapabilitiesChanged(
                    network: android.net.Network,
                    caps: NetworkCapabilities,
                ) {
                    submit(cm, l)
                }
            }
            callback = cb
            executor = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
                Thread(r, "ATX-IfMon")
            }
            cm.registerNetworkCallback(request, cb)
            executor?.submit {
                try {
                    // Push immediately (no leading sleep): early dials need the
                    // default interface NOW. Then retry briefly until accepted.
                    if (!push(cm, l)) {
                        for (attempt in 1..20) {
                            Thread.sleep(250)
                            if (push(cm, l)) break
                        }
                    }
                } catch (_: InterruptedException) {}
            }
            AtlanhixTrace.log("INTERFACE_MONITOR activated (serialized pushes)")
        } catch (e: Exception) {
            AtlanhixTrace.err("INTERFACE_MONITOR activation failed: ${e.message}")
        }
    }

    @Synchronized
    fun stop(context: android.content.Context) {
        try {
            val cm = context.getSystemService(ConnectivityManager::class.java)
            callback?.let { cm.unregisterNetworkCallback(it) }
        } catch (_: Exception) {}
        callback = null
        listener = null
        executor?.shutdownNow()
        executor = null
    }

    private fun submit(cm: ConnectivityManager,
                       l: io.nekohasekai.libbox.InterfaceUpdateListener) {
        executor?.submit { push(cm, l) }
    }

    /** Returns true once the engine accepted a real default interface. */
    private fun push(cm: ConnectivityManager,
                     l: io.nekohasekai.libbox.InterfaceUpdateListener): Boolean {
        AtlanhixTrace.log("DEFAULT_INTERFACE push attempt")
        try {
            // CRITICAL: while our own VpnService is up, activeNetwork IS our tun0.
            // Pushing tun0 makes libbox dial upstream through its own TUN (hairpin
            // loop -> handshake dies). Always pick the best NON-VPN network.
            val network = bestNonVpnNetwork(cm) ?: run {
                AtlanhixTrace.warn("DEFAULT_INTERFACE push: no non-VPN network"); return false
            }
            val lp = cm.getLinkProperties(network) ?: run {
                AtlanhixTrace.warn("DEFAULT_INTERFACE push: linkProperties null"); return false
            }
            val caps = cm.getNetworkCapabilities(network) ?: run {
                AtlanhixTrace.warn("DEFAULT_INTERFACE push: capabilities null"); return false
            }
            val name = lp.interfaceName ?: run {
                AtlanhixTrace.warn("DEFAULT_INTERFACE push: interfaceName null"); return false
            }
            val nif = NetworkInterface.getByName(name) ?: run {
                AtlanhixTrace.warn("DEFAULT_INTERFACE push: NetworkInterface($name) not found")
                return false
            }
            val metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            l.updateDefaultInterface(name, nif.index, metered, metered)
            AtlanhixTrace.log("DEFAULT_INTERFACE $name index=${nif.index} metered=$metered")
            return true
        } catch (e: Exception) {
            AtlanhixTrace.warn("DEFAULT_INTERFACE push failed: ${e.message}")
            return false
        }
    }

    /** Best physical (non-VPN) network: validated > wifi/ethernet > cellular. */
    fun bestNonVpnNetwork(cm: ConnectivityManager): android.net.Network? {
        var best: android.net.Network? = null
        var bestScore = -1
        for (n in cm.allNetworks) {
            try {
                val caps = cm.getNetworkCapabilities(n) ?: continue
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
                if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
                var score = 0
                if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) score += 4
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) score += 4
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) score += 3
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) score += 2
                if (score > bestScore) { bestScore = score; best = n }
            } catch (_: Exception) {}
        }
        return best
    }
}

class InterfaceArray(private val it: Iterator<io.nekohasekai.libbox.NetworkInterface>) :
    NetworkInterfaceIterator {
    override fun hasNext() = it.hasNext()
    override fun next() = it.next()
}

/** Simple StringIterator over a Kotlin list (libbox binding helper). */
class StringArray(private val items: List<String>) : StringIterator {
    private var idx = 0
    constructor(vararg vals: String) : this(vals.toList())
    override fun hasNext() = idx < items.size
    override fun next(): String = items[idx++]
    /** MUST be the real count: Go consumes these via make([]string, 0, Len()) —
     *  a negative Len() panics (makeslice: len out of range) and aborts the process. */
    override fun len(): Int = items.size
}


private class DnsRawCallback(
    private val onAns: (ByteArray, Int) -> Unit,
    private val onErr: (Exception) -> Unit,
) : android.net.DnsResolver.Callback<ByteArray> {
    override fun onAnswer(res: ByteArray, rcode: Int) = onAns(res, rcode)
    override fun onError(e: android.net.DnsResolver.DnsException) = onErr(e)
}

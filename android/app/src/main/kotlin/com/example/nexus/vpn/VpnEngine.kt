package com.example.nexus.vpn

/**
 * The native VPN engine behind the TUN interface.
 *
 * Atlanhix hands the TUN file descriptor produced by [android.net.VpnService]
 * to a real tunneling engine. The canonical engine for this project is
 * sing-box's libbox binding (`LibboxEngine`); see docs/ANDROID_VPN.md for the
 * exact artifact/build requirements and the Gradle source-set that swaps this
 * default implementation for the real one.
 *
 * There is deliberately NO fallback engine that pretends to tunnel: if no
 * engine artifact is present, [start] reports engine-unavailable and the
 * service never reaches a connected state.
 */
interface VpnEngine {
    /**
     * Starts tunneling packets read/written on the TUN [tunFd] according to
     * [configJson] (the full sing-box configuration, with the TUN inbound's
     * `inet4_address`/`inet6_address` matching the fd's interface).
     *
     * Returns once the engine accepted the config; readiness/connectivity is
     * signaled separately via [listener] so the UI state machine only shows
     * "connected" after a real health probe (handled Dart-side).
     */
    fun start(configJson: String, tunFd: Int, listener: EngineEvents)

    /** Stops the engine and releases its resources. Idempotent. */
    fun stop()

    val isRunning: Boolean
}

/** Engine lifecycle callbacks surfaced to the Dart state machine. */
interface EngineEvents {
    fun onStarted()
    fun onFailed(reason: String)
    fun onCrashed(reason: String)
    fun onStopped()
}

/**
 * The DEFAULT engine on this source set: reports honestly that no native
 * engine artifact is bundled. Building the `libbox` variant replaces this
 * class (same package/name) with the real binding — see docs/ANDROID_VPN.md.
 */
class UnavailableEngine : VpnEngine {
    override val isRunning: Boolean get() = false

    override fun start(configJson: String, tunFd: Int, listener: EngineEvents) {
        // Honest failure — never fabricate a tunnel.
        listener.onFailed(
            "engineUnavailable: libbox artifact not bundled in this build; " +
                "see docs/ANDROID_VPN.md"
        )
    }

    override fun stop() {}
}

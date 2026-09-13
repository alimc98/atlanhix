package com.example.nexus.vpn

/**
 * The native VPN engine contract behind the TUN interface.
 *
 * v0.4.1: the REAL engine is [LibboxEngine] (sing-box v1.14.0 libbox, bundled
 * as android/app/libs/libbox.aar) — it does not consume a pre-created fd;
 * instead libbox's tun inbound calls back into the VpnService (SFA model),
 * see [AtlanhixPlatformInterface.openTunForBox]. [EngineEvents] remains the
 * lifecycle surface shared with the Dart state machine.
 *
 * There is deliberately NO fallback engine that pretends to tunnel.
 */
interface EngineEvents {
    fun onStarted()
    fun onFailed(reason: String)
    fun onCrashed(reason: String)
    fun onStopped()
}

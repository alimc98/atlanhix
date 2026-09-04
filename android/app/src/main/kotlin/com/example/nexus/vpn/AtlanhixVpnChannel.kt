package com.example.nexus.vpn

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import org.json.JSONObject

/**
 * Platform-channel contract for the Atlanhix Android VPN runtime (آ§3â€“آ§5).
 *
 * Channel: `dev.atlanhix/vpn`
 *   prepare            â†’ {granted: Bool, needsUserConsent: Bool}
 *   start(configJson)  â†’ {ok: Bool}
 *   stop()             â†’ {ok: Bool}
 *   state()            â†’ {state: String, detail: String?}
 *
 * Permission flow: `prepare()` runs [VpnService.prepare]; when user consent
 * is required the intent is launched with [RC_VPN] and the outcome is
 * delivered back on `permissionResult` via [handlePermissionResult].
 */
class AtlanhixVpnChannel(private val activity: Activity) {

    fun handle(method: String, arg: JSONObject?): JSONObject = when (method) {
        "prepare" -> prepare()
        "start" -> start(arg ?: JSONObject())
        "stop" -> stop()
        "state" -> JSONObject()
            .put("state", AtlanhixVpnService.state.name)
            .put(
                "detail",
                AtlanhixVpnService.stateDetail ?: JSONObject.NULL
            )
        else -> JSONObject().put("error", "unknown method: $method")
    }

    fun prepare(): JSONObject {
        val intent: Intent? = VpnService.prepare(activity)
        return if (intent == null) {
            JSONObject().put("granted", true)
                .put("needsUserConsent", false)
        } else {
            consentIntent = intent
            JSONObject().put("granted", false)
                .put("needsUserConsent", true)
        }
    }

    fun consumeConsentIntent(): Intent? {
        val i = consentIntent
        consentIntent = null
        return i
    }

    fun handlePermissionResult(granted: Boolean): JSONObject =
        JSONObject().put("granted", granted)

    private fun start(config: JSONObject): JSONObject {
        AtlanhixVpnService.pendingConfig = config
        val intent = Intent(activity, AtlanhixVpnService::class.java)
            .setAction(AtlanhixVpnService.ACTION_START)
        activity.startForegroundService(intent)
        return JSONObject().put("ok", true)
    }

    private fun stop(): JSONObject {
        val intent = Intent(activity, AtlanhixVpnService::class.java)
            .setAction(AtlanhixVpnService.ACTION_STOP)
        activity.startService(intent)
        return JSONObject().put("ok", true)
    }

    private var consentIntent: Intent? = null

    companion object {
        const val RC_VPN = 4141 // 'AT'
        const val CHANNEL = "dev.atlanhix/vpn"
    }
}


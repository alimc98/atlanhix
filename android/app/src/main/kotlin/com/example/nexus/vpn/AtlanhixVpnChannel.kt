package com.example.nexus.vpn

import android.app.Activity
import android.content.Intent
import android.net.Uri
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
            .put("generation", AtlanhixVpnService.generation ?: JSONObject.NULL)
            .put(
                "detail",
                AtlanhixVpnService.stateDetail ?: JSONObject.NULL
            )
            .put(
                "errorCode",
                AtlanhixVpnService.errorCode ?: JSONObject.NULL
            )
            // v0.4.4 §user-2: real engine traffic rides the existing
            // 1-second state poll — Dart computes speed deltas from it.
            .put("up", AtlanhixTraffic.up)
            .put("down", AtlanhixTraffic.down)
            .put("conns", AtlanhixTraffic.conns)
        // v0.4.1 §11 — REAL PackageManager inventory for the app picker.
        "installedApps" -> JSONObject().put("apps", InstalledAppsSource.list(activity.packageManager))
        // v0.4.4 §user-5 — PROXY MODE: best-effort global http_proxy.
        "setProxy" -> setProxy(arg ?: JSONObject())
        "clearProxy" -> clearProxy()
        // v0.4.7 §user — updater: open the release APK URL in the browser
        // (user-visible download; no in-app sideloading).
        "openUrl" -> {
            val url = arg?.optString("url").orEmpty()
            try {
                activity.startActivity(
                    Intent(Intent.ACTION_VIEW, Uri.parse(url))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                JSONObject().put("ok", true)
            } catch (e: Exception) {
                JSONObject().put("ok", false).put("error", "${e.message}")
            }
        }
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
        // NOTE: the generation is adopted inside onStartCommand (not here) —
        // echoing it before the service processes the intent would let a
        // poll pair the NEW nonce with the OLD session's state.
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

    private fun setProxy(o: JSONObject): JSONObject = try {
        val port = o.optInt("port", 0)
        require(port in 1..65535) { "bad port" }
        android.provider.Settings.Global.putString(
            activity.contentResolver, "http_proxy", "127.0.0.1:$port")
        JSONObject().put("ok", true).put("applied", true)
    } catch (sec: SecurityException) {
        // No WRITE_SECURE_SETTINGS (non-rooted, stock MIUI): the TUN is off
        // and the local mixed port still serves 127.0.0.1 — the user can
        // point Wi-Fi proxy at it manually. Honest degrade, never a lie.
        android.util.Log.w("AtlanhixVpn", "global proxy refused: ${'$'}{sec.message}")
        JSONObject().put("ok", true).put("applied", false)
            .put("error", "global http_proxy needs WRITE_SECURE_SETTINGS (adb grant) — proxy works locally on the chosen port meanwhile")
    } catch (e: Exception) {
        JSONObject().put("ok", false).put("error", e.message ?: "setProxy failed")
    }

    private fun clearProxy(): JSONObject = try {
        android.provider.Settings.Global.putString(activity.contentResolver, "http_proxy", null)
        JSONObject().put("ok", true)
    } catch (e: Exception) {
        JSONObject().put("ok", false).put("error", e.message ?: "clearProxy failed")
    }

    private var consentIntent: Intent? = null

    companion object {
        const val RC_VPN = 4141 // 'AT'
        const val CHANNEL = "dev.atlanhix/vpn"
    }
}


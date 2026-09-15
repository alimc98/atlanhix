package com.example.nexus.vpn

import android.app.Activity
import android.content.Intent
import android.os.Process
import org.json.JSONObject
import java.io.File

/**
 * Platform-channel contract for the Xray runtime (`:xray` process, exec'd
 * libxray_core.so — see [XrayCoreService]).
 *
 * Channel: `dev.atlanhix/xray`
 *   status  -> {available, running, socksPort, version, uid}
 *   start   -> {ok, running, socksPort}
 *   stop    -> {ok}
 */
class AtlanhixXrayChannel(private val activity: Activity) {

    fun handle(method: String, arg: JSONObject?): JSONObject = when (method) {
        "status" -> status()
        "start" -> start(arg ?: JSONObject())
        "stop" -> stop()
        else -> JSONObject().put("error", "unknown method: $method")
    }

    private fun binaryPresent(): Boolean = try {
        File(activity.applicationInfo.nativeLibraryDir, "libxray_core.so")
            .exists()
    } catch (_: Throwable) {
        false
    }

    private fun status(): JSONObject {
        val (live, port) = XrayCoreService.readState(activity.filesDir)
        return JSONObject()
            .put("available", binaryPresent())
            .put("running", live)
            .put("socksPort", port)
            .put("uid", Process.myUid())
    }

    private fun start(arg: JSONObject): JSONObject {
        val config = arg.optString("config")
        val port = arg.optInt("socksPort", 0)
        if (config.isEmpty()) {
            return JSONObject().put("ok", false).put("error", "no config")
        }
        if (!binaryPresent()) {
            return JSONObject().put("ok", false).put("error", "xray binary absent")
        }
        // FGS start (API 26+): survives MIUI app-idle kills that left
        // every xhttp node dead on-device while identical configs passed
        // on PC (v0.4.4 phone connection root-cause fix).
        val intent = Intent(activity, XrayCoreService::class.java)
            .setAction(XrayCoreService.ACTION_START)
            .putExtra(XrayCoreService.EXTRA_CONFIG, config)
            .putExtra(XrayCoreService.EXTRA_SOCKS_PORT, port)
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            activity.startForegroundService(intent)
        } else {
            activity.startService(intent)
        }
        return JSONObject().put("ok", true).put("socksPort", port)
    }

    private fun stop(): JSONObject {
        activity.startService(
            Intent(activity, XrayCoreService::class.java)
                .setAction(XrayCoreService.ACTION_STOP))
        return JSONObject().put("ok", true)
    }

    companion object {
        const val CHANNEL = "dev.atlanhix/xray"
    }
}

package com.atlanhix.app.vpn

import android.app.Activity
import android.content.Intent
import android.os.Process
import org.json.JSONObject
import java.io.File

/**
 * Platform-channel contract for the mihomo runtime (`:mihomo` process, exec'd
 * libmihomo.so — see [MihomoCoreService]).
 *
 * Channel: `dev.atlanhix/mihomo`
 *   status  -> {available, running, mixedPort, uid}
 *   start   -> {ok, running, mixedPort}
 *   stop    -> {ok}
 */
class AtlanhixMihomoChannel(private val activity: Activity) {

    fun handle(method: String, arg: JSONObject?): JSONObject = when (method) {
        "status" -> status()
        "start" -> start(arg ?: JSONObject())
        "stop" -> stop()
        else -> JSONObject().put("error", "unknown method: $method")
    }

    private fun binaryPresent(): Boolean = try {
        File(activity.applicationInfo.nativeLibraryDir, "libmihomo.so")
            .exists()
    } catch (_: Throwable) {
        false
    }

    private fun status(): JSONObject {
        val (live, port) = MihomoCoreService.readState(activity.filesDir)
        return JSONObject()
            .put("available", binaryPresent())
            .put("running", live)
            .put("mixedPort", port)
            .put("uid", Process.myUid())
    }

    private fun start(arg: JSONObject): JSONObject {
        val config = arg.optString("config")
        val port = arg.optInt("mixedPort", 0)
        if (config.isEmpty()) {
            return JSONObject().put("ok", false).put("error", "no config")
        }
        if (!binaryPresent()) {
            return JSONObject().put("ok", false).put("error", "mihomo binary absent")
        }
        val intent = Intent(activity, MihomoCoreService::class.java)
            .setAction(MihomoCoreService.ACTION_START)
            .putExtra(MihomoCoreService.EXTRA_CONFIG, config)
            .putExtra(MihomoCoreService.EXTRA_MIXED_PORT, port)
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            activity.startForegroundService(intent)
        } else {
            activity.startService(intent)
        }
        return JSONObject().put("ok", true).put("mixedPort", port)
    }

    private fun stop(): JSONObject {
        activity.startService(
            Intent(activity, MihomoCoreService::class.java)
                .setAction(MihomoCoreService.ACTION_STOP))
        return JSONObject().put("ok", true)
    }

    companion object {
        const val CHANNEL = "dev.atlanhix/mihomo"
    }
}

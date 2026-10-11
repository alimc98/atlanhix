package com.atlanhix.app

import android.content.Intent
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import com.atlanhix.app.vpn.AtlanhixProbeChannel
import com.atlanhix.app.vpn.AtlanhixVpnChannel
import com.atlanhix.app.vpn.AtlanhixXrayChannel
import com.atlanhix.app.vpn.AtlanhixMihomoChannel
import com.atlanhix.app.vpn.AtlanhixUpdaterChannel
import com.atlanhix.app.vpn.InstalledAppsSource

class MainActivity : FlutterActivity() {

    private companion object {
        const val TAG = "atlanhix"
    }

    private var vpnChannel: AtlanhixVpnChannel? = null
    private var vpnMethodSink: MethodChannel.Result? = null
    private var updaterChannel: AtlanhixUpdaterChannel? = null

    /**
     * v0.6.9 §update-fix — MethodChannel arguments arrive as a decoded
     * Map, and `Map.toString()` is JAVA MAP SYNTAX (`{url=https://…}`),
     * NOT JSON. Android's lenient org.json accepts the unquoted form but
     * treats `//` as a line comment, so EVERY payload carrying a URL died
     * at the scheme separator:
     *
     *   Unterminated object at character 27 of
     *   {version=v0.6.8, url=https://github.com/…}
     *
     * That is why the in-app updater's Download button failed while its
     * status/install payloads (no `//`) parsed fine. Convert Maps (and
     * nested lists/maps) structurally instead of stringifying them.
     */
    private fun toJsonValue(v: Any?): Any? = when (v) {
        null -> JSONObject.NULL
        is Map<*, *> -> JSONObject().also { o ->
            v.forEach { (k, w) -> o.put(k.toString(), toJsonValue(w)) }
        }
        // Android's org.json JSONArray spells it put() (add() is the
        // JSON.org reference impl — unresolved against compileSdk here).
        is List<*> -> JSONArray().also { a -> v.forEach { a.put(toJsonValue(it)) } }
        is Boolean, is Number, is String -> v
        else -> v.toString()
    }

    private fun argsToJson(raw: Any?): JSONObject? = when (raw) {
        null -> null
        is JSONObject -> raw
        is Map<*, *> -> toJsonValue(raw) as JSONObject
        // A pre-encoded JSON string (some Dart callers send one) parses
        // verbatim; scalars keep the old lenient path.
        else -> JSONObject(raw.toString())
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AtlanhixXrayChannel.CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                val arg = argsToJson(call.arguments())
                result.success(xrayChannelOrNew().handle(call.method, arg).toString())
            } catch (e: Exception) {
                result.error("xray_channel", e.message, null)
            } catch (t: Throwable) {
                Log.w(TAG, "core unavailable on ${Build.SUPPORTED_ABIS.joinToString()}: ${t.message}")
                result.error("core_unavailable", t.message ?: "core_unavailable", null)
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AtlanhixMihomoChannel.CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                val arg = argsToJson(call.arguments())
                result.success(mihomoChannelOrNew().handle(call.method, arg).toString())
            } catch (e: Exception) {
                result.error("mihomo_channel", e.message, null)
            } catch (t: Throwable) {
                Log.w(TAG, "core unavailable on ${Build.SUPPORTED_ABIS.joinToString()}: ${t.message}")
                result.error("core_unavailable", t.message ?: "core_unavailable", null)
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AtlanhixProbeChannel.CHANNEL
        ).setMethodCallHandler { call, result ->
            val appContext = applicationContext
            Thread {
                try {
                    val arg = argsToJson(call.arguments())
                    val resp = probeChannelOrNew().handle(call.method, arg)
                    runOnUiThread { result.success(resp.toString()) }
                } catch (e: Exception) {
                    runOnUiThread { result.error("probe_channel", e.message, null) }
                } catch (t: Throwable) {
                    runOnUiThread { result.error("core_unavailable", t.message, null) }
                }
            }.start()
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AtlanhixUpdaterChannel.CHANNEL
        ).setMethodCallHandler { call, result ->
            Thread {
                try {
                    val arg = argsToJson(call.arguments())
                    val resp = updaterChannelOrNew().handle(call.method, arg)
                    runOnUiThread { result.success(resp.toString()) }
                } catch (e: Exception) {
                    runOnUiThread { result.error("updater_channel", e.message, null) }
                } catch (t: Throwable) {
                    runOnUiThread { result.error("core_unavailable", t.message, null) }
                }
            }.start()
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AtlanhixVpnChannel.CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                val arg = argsToJson(call.arguments())
                when (call.method) {
                    "prepare" -> {
                        val resp = vpnChannelOrNew().prepare()
                        if (resp.optBoolean("needsUserConsent")) {
                            vpnMethodSink = result
                            startActivityForResult(
                                vpnChannelOrNew().consumeConsentIntent(),
                                AtlanhixVpnChannel.RC_VPN
                            )
                        } else {
                            result.success(resp.toString())
                        }
                    }
                    "installedApps" -> {
                        val appContext = applicationContext
                        Thread {
                            try {
                                val apps = InstalledAppsSource.list(appContext.packageManager)
                                runOnUiThread { result.success(apps.toString()) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("vpn_channel", e.message, null) }
                            }
                        }.start()
                    }
                    else -> result.success(vpnChannelOrNew().handle(call.method, arg).toString())
                }
            } catch (e: Exception) {
                result.error("vpn_channel", e.message, null)
            } catch (t: Throwable) {
                Log.w(TAG, "core unavailable on ${Build.SUPPORTED_ABIS.joinToString()}: ${t.message}")
                result.error("core_unavailable", t.message ?: "core_unavailable", null)
            }
        }
    }

    private fun vpnChannelOrNew(): AtlanhixVpnChannel =
        vpnChannel ?: AtlanhixVpnChannel(this).also { vpnChannel = it }

    private fun updaterChannelOrNew(): AtlanhixUpdaterChannel =
        updaterChannel ?: AtlanhixUpdaterChannel(this).also { updaterChannel = it }

    private var xrayChannel: AtlanhixXrayChannel? = null
    private fun xrayChannelOrNew(): AtlanhixXrayChannel =
        xrayChannel ?: AtlanhixXrayChannel(this).also { xrayChannel = it }

    private var mihomoChannel: AtlanhixMihomoChannel? = null
    private fun mihomoChannelOrNew(): AtlanhixMihomoChannel =
        mihomoChannel ?: AtlanhixMihomoChannel(this).also { mihomoChannel = it }

    private var probeChannel: AtlanhixProbeChannel? = null
    private fun probeChannelOrNew(): AtlanhixProbeChannel =
        probeChannel ?: AtlanhixProbeChannel(this).also { probeChannel = it }

    override fun onDestroy() {
        // The probe engine is a child of the ACTIVITY-scoped channel object;
        // without this a rotated/recreated activity leaks a running Box.
        probeChannel?.handle("probeStop", null)
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == AtlanhixVpnChannel.RC_VPN) {
            val granted = resultCode == RESULT_OK
            vpnMethodSink?.success(
                vpnChannelOrNew().handlePermissionResult(granted).toString()
            )
            vpnMethodSink = null
        }
    }
}


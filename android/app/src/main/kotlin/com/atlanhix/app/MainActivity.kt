package com.atlanhix.app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import com.atlanhix.app.vpn.AtlanhixProbeChannel
import com.atlanhix.app.vpn.AtlanhixVpnChannel
import com.atlanhix.app.vpn.AtlanhixXrayChannel
import com.atlanhix.app.vpn.AtlanhixMihomoChannel
import com.atlanhix.app.vpn.InstalledAppsSource

class MainActivity : FlutterActivity() {

    private var vpnChannel: AtlanhixVpnChannel? = null
    private var vpnMethodSink: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AtlanhixXrayChannel.CHANNEL
        ).setMethodCallHandler { call, result ->
            // v0.4.3: Xray runtime control (`:xray` process). JSON-string
            // contract mirrors the VPN channel.
            try {
                val rawArg: Any? = call.arguments()
                val arg: JSONObject? =
                    if (rawArg == null) null else JSONObject(rawArg.toString())
                result.success(xrayChannelOrNew().handle(call.method, arg).toString())
            } catch (e: Exception) {
                result.error("xray_channel", e.message, null)
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AtlanhixMihomoChannel.CHANNEL
        ).setMethodCallHandler { call, result ->
            // v0.5.3: mihomo runtime control (`:mihomo` process) — same
            // JSON-string contract as the Xray channel.
            try {
                val rawArg: Any? = call.arguments()
                val arg: JSONObject? =
                    if (rawArg == null) null else JSONObject(rawArg.toString())
                result.success(mihomoChannelOrNew().handle(call.method, arg).toString())
            } catch (e: Exception) {
                result.error("mihomo_channel", e.message, null)
            }
        }
        // v0.4.9 §user: transient probe engine (real delay tests with no
        // active VPN). libbox start is a blocking native call — run it off
        // the MAIN thread or ANR (same pattern as installedApps above).
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AtlanhixProbeChannel.CHANNEL
        ).setMethodCallHandler { call, result ->
            val appContext = applicationContext
            Thread {
                try {
                    val rawArg: Any? = call.arguments()
                    val arg: JSONObject? =
                        if (rawArg == null) null else JSONObject(rawArg.toString())
                    val resp = probeChannelOrNew().handle(call.method, arg)
                    runOnUiThread { result.success(resp.toString()) }
                } catch (e: Exception) {
                    runOnUiThread { result.error("probe_channel", e.message, null) }
                }
            }.start()
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AtlanhixVpnChannel.CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                val rawArg: Any? = call.arguments()
                val arg: JSONObject? =
                    if (rawArg == null) null else JSONObject(rawArg.toString())
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
                    // v0.4.7 §fix(black-screen): the PackageManager scan
                    // (labels + launch intents for ~200 packages) blocked the
                    // MAIN thread for seconds and some broken half-uninstalled
                    // packages (e.g. com.openai.chatgpt with a dangling APK
                    // path) even threw `Failed to open APK` mid-scan — the
                    // apps-routing screen rendered BLACK. The scan now runs on
                    // a background thread; only the channel reply hops back.
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
            }
        }
    }

    private fun vpnChannelOrNew(): AtlanhixVpnChannel =
        vpnChannel ?: AtlanhixVpnChannel(this).also { vpnChannel = it }

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


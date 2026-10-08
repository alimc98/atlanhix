package com.atlanhix.app

import android.content.Intent
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AtlanhixXrayChannel.CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                val rawArg: Any? = call.arguments()
                val arg: JSONObject? =
                    if (rawArg == null) null else JSONObject(rawArg.toString())
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
                val rawArg: Any? = call.arguments()
                val arg: JSONObject? =
                    if (rawArg == null) null else JSONObject(rawArg.toString())
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
                    val rawArg: Any? = call.arguments()
                    val arg: JSONObject? =
                        if (rawArg == null) null else JSONObject(rawArg.toString())
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
                    val rawArg: Any? = call.arguments()
                    val arg: JSONObject? =
                        if (rawArg == null) null else JSONObject(rawArg.toString())
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


package com.example.nexus

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import com.example.nexus.vpn.AtlanhixVpnChannel
import com.example.nexus.vpn.AtlanhixXrayChannel

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
                    // v0.4.1 §11: installedApps returns a JSONArray under
                    // "apps"; the generic handler only ships JSONObject, so
                    // unwrap here and pass the array text directly.
                    "installedApps" -> result.success(
                        vpnChannelOrNew().handle(call.method, arg)
                            .getJSONArray("apps").toString()
                    )
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


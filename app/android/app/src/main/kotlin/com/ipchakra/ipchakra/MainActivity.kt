package com.ipchakra.ipchakra

import android.content.Intent
import android.provider.Settings
import id.laskarmedia.openvpn_flutter.OpenVPNFlutterPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // openvpn_flutter needs the VPN permission result forwarded.
    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        OpenVPNFlutterPlugin.connectWhileGranted(requestCode == 24 && resultCode == RESULT_OK)
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Opens the system VPN settings page (where Android keeps
        // Always-on VPN and its "Block connections without VPN"
        // lockdown) for the Settings screen's leak-protection note.
        // Reports false when the intent cannot be resolved on this
        // device, so the app can say so instead of faking success.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ipchakra/system_settings")
            .setMethodCallHandler { call, result ->
                if (call.method == "openVpnSettings") {
                    val intent = Intent(Settings.ACTION_VPN_SETTINGS)
                    val canOpen = intent.resolveActivity(packageManager) != null
                    if (canOpen) {
                        try {
                            startActivity(intent)
                        } catch (e: Exception) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                    }
                    result.success(canOpen)
                } else {
                    result.notImplemented()
                }
            }
    }
}

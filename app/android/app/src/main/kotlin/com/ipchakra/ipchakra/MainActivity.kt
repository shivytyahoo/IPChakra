package com.ipchakra.ipchakra

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import id.laskarmedia.openvpn_flutter.OpenVPNFlutterPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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
        // In-app updater (Settings → Check for update): hand a
        // downloaded APK to the system package installer through a
        // FileProvider URI, and open the release page in the
        // browser when a release carries no APK asset. Both report
        // false when the intent cannot be resolved, so the app can
        // say so instead of pretending the tap worked. Android
        // itself asks the user to allow "Install unknown apps" for
        // IPChakra on first use.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ipchakra/app_update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        try {
                            val uri = FileProvider.getUriForFile(
                                this,
                                "${applicationContext.packageName}.fileprovider",
                                File(path),
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(
                                    uri,
                                    "application/vnd.android.package-archive",
                                )
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            val canOpen =
                                intent.resolveActivity(packageManager) != null
                            if (canOpen) startActivity(intent)
                            result.success(canOpen)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        try {
                            val intent =
                                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            val canOpen =
                                intent.resolveActivity(packageManager) != null
                            if (canOpen) startActivity(intent)
                            result.success(canOpen)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

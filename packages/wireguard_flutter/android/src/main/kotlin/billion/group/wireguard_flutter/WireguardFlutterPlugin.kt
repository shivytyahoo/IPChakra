package billion.group.wireguard_flutter


import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry

import android.Manifest
import android.app.Activity
import io.flutter.embedding.android.FlutterActivity
import android.content.Intent
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log
import com.beust.klaxon.Klaxon
import com.wireguard.android.backend.*
import com.wireguard.crypto.Key
import com.wireguard.crypto.KeyPair
import io.flutter.plugin.common.EventChannel
import kotlinx.coroutines.*
import java.util.*


import kotlinx.coroutines.launch
import java.io.ByteArrayInputStream

/** WireguardFlutterPlugin */

const val PERMISSIONS_REQUEST_CODE = 10014
const val NOTIFICATIONS_REQUEST_CODE = 10015
const val METHOD_CHANNEL_NAME = "billion.group.wireguard_flutter/wgcontrol"
const val METHOD_EVENT_NAME = "billion.group.wireguard_flutter/wgstage"

class WireguardFlutterPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var tunnelName: String
    private val futureBackend = CompletableDeferred<Backend>()
    private var vpnStageSink: EventChannel.EventSink? = null
    private val scope = CoroutineScope(Job() + Dispatchers.Main.immediate)
    private var backend: Backend? = null
    private var havePermission = false
    private lateinit var context: Context
    private var activity: Activity? = null
    private var config: com.wireguard.config.Config? = null
    private var tunnel: WireGuardTunnel? = null
    private val TAG = "NVPN"
    var isVpnChecked = false
    companion object {
        private var state: String = "no_connection"

        // IPChakra patch (see PATCHES.md, Patch 2): the live plugin
        // instance, so the connection notification's Disconnect
        // receiver can reach the backend. Set on engine attach,
        // cleared on detach.
        @Volatile
        var activeInstance: WireguardFlutterPlugin? = null

        fun getStatus(): String {
            return state
        }

        /**
         * Entry point for the notification's Disconnect action:
         * performs exactly the same backend stop as an in-app
         * disconnect, so the tunnel's state-change callback reports
         * the stop to Dart like any other native stop. With no live
         * plugin the notification is stale (the tunnel lived in this
         * process) and is simply removed.
         */
        fun stopFromNotification(context: Context) {
            val plugin = activeInstance
            if (plugin != null) {
                plugin.performDisconnect(null)
            } else {
                WgNotification.cancel(context)
            }
        }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        this.havePermission =
            (requestCode == PERMISSIONS_REQUEST_CODE) && (resultCode == Activity.RESULT_OK)
        return havePermission
    }

    override fun onAttachedToActivity(activityPluginBinding: ActivityPluginBinding) {
        this.activity = activityPluginBinding.activity as FlutterActivity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        this.activity = null
    }

    override fun onReattachedToActivityForConfigChanges(activityPluginBinding: ActivityPluginBinding) {
        this.activity = activityPluginBinding.activity as FlutterActivity
    }

    override fun onDetachedFromActivity() {
        this.activity = null
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, METHOD_CHANNEL_NAME)
        events = EventChannel(flutterPluginBinding.binaryMessenger, METHOD_EVENT_NAME)
        context = flutterPluginBinding.applicationContext

        scope.launch(Dispatchers.IO) {
            try {
                backend = createBackend()
                futureBackend.complete(backend!!)
            } catch (e: Throwable) {
                Log.e(TAG, Log.getStackTraceString(e))
            }
        }

        activeInstance = this
        channel.setMethodCallHandler(this)
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                isVpnChecked = false
                vpnStageSink = events
            }

            override fun onCancel(arguments: Any?) {
                isVpnChecked = false
                vpnStageSink = null
            }
        })

    }

    private fun createBackend(): Backend {
        if (backend == null) {
            backend = GoBackend(context)
        }
        return backend as Backend
    }

    private fun flutterSuccess(result: Result, o: Any) {
        scope.launch(Dispatchers.Main) {
            result.success(o)
        }
    }

    private fun flutterError(result: Result, error: String) {
        scope.launch(Dispatchers.Main) {
            result.error(error, null, null)
        }
    }

    private fun flutterNotImplemented(result: Result) {
        scope.launch(Dispatchers.Main) {
            result.notImplemented()
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {

        when (call.method) {
            "initialize" -> setupTunnel(call.argument<String>("localizedDescription").toString(), result)
            "start" -> {
                connect(call.argument<String>("wgQuickConfig").toString(), result)

                if (!isVpnChecked) {
                    if (isVpnActive()) {
                        state = "connected"
                        isVpnChecked = true
                        println("VPN is active")
                    } else {
                        state = "disconnected"
                        isVpnChecked = true
                        println("VPN is not active")
                    }
                }
            }
            "stop" -> {
                disconnect(result)
            }
            "stage" -> {
                result.success(getStatus())
            }
            "checkPermission" -> {
                checkPermission()
                result.success(null)
            }
            "requestNotificationPermission" -> {
                // IPChakra patch (see PATCHES.md, Patch 2): the
                // connection notification needs POST_NOTIFICATIONS on
                // Android 13+. Upstream only ever requested the VPN
                // consent, which is why a Free-mode connect could not
                // show a notification even once one existed.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val act = activity
                    if (act != null &&
                        ActivityCompat.checkSelfPermission(act, Manifest.permission.POST_NOTIFICATIONS) !=
                        PackageManager.PERMISSION_GRANTED
                    ) {
                        ActivityCompat.requestPermissions(
                            act,
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            NOTIFICATIONS_REQUEST_CODE
                        )
                    }
                }
                result.success(null)
            }
            else -> flutterNotImplemented(result)
        }
    }
    private fun isVpnActive(): Boolean {
        try {
            val connectivityManager =
                context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val activeNetwork = connectivityManager.activeNetwork
                val networkCapabilities = connectivityManager.getNetworkCapabilities(activeNetwork)
                return networkCapabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
            } else {
                return false
            }
        } catch (e: Exception) {
            Log.e(TAG, "isVpnActive - ERROR - ${e.message}")
            return false
        }
    }
    private fun updateStage(stage: String?) {
        scope.launch(Dispatchers.Main) {
            val updatedStage = stage ?: "no_connection"
            state = updatedStage
            vpnStageSink?.success(updatedStage.lowercase(Locale.ROOT))
            // IPChakra patch (see PATCHES.md, Patch 2): keep the
            // persistent connection notification in step with the
            // tunnel — shown while connected, removed when the
            // tunnel is fully down, whatever caused the change
            // (in-app disconnect, notification action, system stop).
            when (updatedStage.lowercase(Locale.ROOT)) {
                "connected" -> WgNotification.show(context)
                "disconnected", "no_connection" -> WgNotification.cancel(context)
            }
        }
    }
    private fun updateStageFromState(state: Tunnel.State) {
        scope.launch(Dispatchers.Main) {
            when (state) {
                Tunnel.State.UP -> updateStage("connected")
                Tunnel.State.DOWN -> updateStage("disconnected")
                else -> updateStage("wait_connection")
            }
        }
    }
    private fun disconnect(result: Result) {
        performDisconnect(result)
    }

    /**
     * The one tunnel stop, shared by the method channel and by the
     * connection notification's Disconnect action (IPChakra patch,
     * Patch 2 — [result] is null in that case). Behaviour is
     * otherwise identical to upstream.
     */
    fun performDisconnect(result: Result?) {
        scope.launch(Dispatchers.IO) {
            try {
                if (futureBackend.await().runningTunnelNames.isEmpty()) {
                    updateStage("disconnected")
                    throw Exception("Tunnel is not running")
                }
                updateStage("disconnecting")
                futureBackend.await().setState(
                    tunnel(tunnelName) { state ->
                        scope.launch(Dispatchers.Main) {
                            Log.i(TAG, "onStateChange - $state")
                            updateStageFromState(state)
                        }
                    }, Tunnel.State.DOWN, config
                )
                Log.i(TAG, "Disconnect - success!")
                if (result != null) {
                    flutterSuccess(result, "")
                }
            } catch (e: BackendException) {
                Log.e(TAG, "Disconnect - BackendException - ERROR - ${e.reason}", e)
                if (result != null) {
                    flutterError(result, e.reason.toString())
                }
            } catch (e: Throwable) {
                Log.e(TAG, "Disconnect - Can't disconnect from tunnel: ${e.message}")
                if (result != null) {
                    flutterError(result, e.message.toString())
                }
            }
        }
    }

    private fun connect(wgQuickConfig: String, result: Result) {
        scope.launch(Dispatchers.IO) {
            try {
                if (!havePermission) {
                    checkPermission()
                    throw Exception("Permissions are not given")
                }
                updateStage("prepare")
                val inputStream = ByteArrayInputStream(wgQuickConfig.toByteArray())
                config = com.wireguard.config.Config.parse(inputStream)
                updateStage("connecting")
                futureBackend.await().setState(
                    tunnel(tunnelName) { state ->
                        scope.launch(Dispatchers.Main) {
                            Log.i(TAG, "onStateChange - $state")
                            updateStageFromState(state)
                        }
                    }, Tunnel.State.UP, config
                )
                Log.i(TAG, "Connect - success!")
                flutterSuccess(result, "")
            } catch (e: BackendException) {
                Log.e(TAG, "Connect - BackendException - ERROR - ${e.reason}", e)
                flutterError(result, e.reason.toString())
            } catch (e: Throwable) {
                Log.e(TAG, "Connect - Can't connect to tunnel: $e", e)
                flutterError(result, e.message.toString())
            }
        }
    }

    private fun setupTunnel(localizedDescription: String, result: Result) {
        scope.launch(Dispatchers.IO) {
            if (Tunnel.isNameInvalid(localizedDescription)) {
                flutterError(result, "Invalid Name")
                return@launch
            }
            tunnelName = localizedDescription
            checkPermission()
            result.success(null)
        }
    }

    private fun checkPermission() {
        val intent = GoBackend.VpnService.prepare(this.activity)
        if (intent != null) {
            havePermission = false
            this.activity?.startActivityForResult(intent, PERMISSIONS_REQUEST_CODE)
        } else {
            havePermission = true
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (activeInstance === this) {
            activeInstance = null
        }
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        isVpnChecked = false
    }

    private fun tunnel(name: String, callback: StateChangeCallback? = null): WireGuardTunnel {
        if (tunnel == null) {
            tunnel = WireGuardTunnel(name, callback)
        }
        return tunnel as WireGuardTunnel
    }
}

typealias StateChangeCallback = (Tunnel.State) -> Unit

class WireGuardTunnel(
    private val name: String, private val onStateChanged: StateChangeCallback? = null
) : Tunnel {

    override fun getName() = name

    override fun onStateChange(newState: Tunnel.State) {
        onStateChanged?.invoke(newState)
    }

}


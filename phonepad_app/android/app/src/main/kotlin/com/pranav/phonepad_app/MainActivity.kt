package com.pranav.phonepad_app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    companion object {
        const val OVERLAY_CHANNEL = "com.pranav.phonepad_app/overlay"
        const val REQUEST_OVERLAY_PERMISSION = 1001
    }

    private var methodChannel: MethodChannel? = null
    private var overlayService: OverlayService? = null
    private var pendingResult: MethodChannel.Result? = null

    // ── Service connection ────────────────────────────────────────────
    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            overlayService = (binder as? OverlayService.LocalBinder)?.getService()
            overlayService?.setEventCallback { payload ->
                // Forward events from the overlay back to Flutter on the main thread
                runOnUiThread {
                    methodChannel?.invokeMethod("send", payload)
                }
            }
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            overlayService = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            OVERLAY_CHANNEL
        )

        methodChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> handleRequestPermission(result)
                "start"             -> handleStart(call, result)
                "stop"              -> handleStop(result)
                else                -> result.notImplemented()
            }
        }
    }

    // ── Permission ────────────────────────────────────────────────────
    private fun handleRequestPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            !Settings.canDrawOverlays(this)
        ) {
            pendingResult = result
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName")
            )
            startActivityForResult(intent, REQUEST_OVERLAY_PERMISSION)
        } else {
            result.success(true)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_OVERLAY_PERMISSION) {
            val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                Settings.canDrawOverlays(this) else true
            pendingResult?.success(granted)
            pendingResult = null
        }
    }

    // ── Start overlay ─────────────────────────────────────────────────
    private fun handleStart(call: MethodCall, result: MethodChannel.Result) {
        val wsUrl       = call.argument<String>("wsUrl")       ?: ""
        val serverKey   = call.argument<String>("serverKey")   ?: ""
        val sensitivity = (call.argument<Double>("sensitivity") ?: 2.5).toFloat()
        val scrollSpeed = (call.argument<Double>("scrollSpeed") ?: 5.0).toFloat()
        val naturalScroll = call.argument<Boolean>("naturalScroll") ?: false

        val intent = Intent(this, OverlayService::class.java).apply {
            putExtra("wsUrl",        wsUrl)
            putExtra("serverKey",    serverKey)
            putExtra("sensitivity",  sensitivity)
            putExtra("scrollSpeed",  scrollSpeed)
            putExtra("naturalScroll", naturalScroll)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
        result.success(null)
    }

    // ── Stop overlay ──────────────────────────────────────────────────
    private fun handleStop(result: MethodChannel.Result) {
        try { unbindService(serviceConnection) } catch (_: Exception) {}
        overlayService = null
        stopService(Intent(this, OverlayService::class.java))
        result.success(null)
    }

    override fun onDestroy() {
        try { unbindService(serviceConnection) } catch (_: Exception) {}
        super.onDestroy()
    }
}
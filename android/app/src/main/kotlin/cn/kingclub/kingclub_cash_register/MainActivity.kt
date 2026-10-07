package cn.kingclub.kingclub_cash_register

import android.os.Build
import android.view.KeyEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var scanner: ScannerBridge? = null
    private var printerDiscovery: PrinterDiscoveryBridge? = null
    private var printerStatus: PrinterStatusBridge? = null
    private var usbPrinterPermission: UsbPrinterPermissionBridge? = null
    private var usbRasterOutput: UsbRasterOutputBridge? = null

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (scanner?.onKeyEvent(event) == true) return true
        return super.dispatchKeyEvent(event)
    }

    override fun onResume() {
        super.onResume()
        scanner?.setForeground(true)
        usbRasterOutput?.setForeground(true)
        window.decorView.post { if (hasWindowFocus()) hideSystemBars() }
    }
    override fun onPause() { scanner?.setForeground(false); usbRasterOutput?.setForeground(false); super.onPause() }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        scanner?.setForeground(hasFocus)
        usbRasterOutput?.setForeground(hasFocus)
        usbPrinterPermission?.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    @Suppress("DEPRECATION")
    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.apply {
                systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                hide(WindowInsets.Type.systemBars())
            }
        } else {
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        io.flutter.plugin.common.MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "cn.kingclub.cashier/product-images").setMethodCallHandler { call, result ->
            if (call.method == "directory") {
                result.success(java.io.File(noBackupFilesDir, "product-images-v1").absolutePath)
            } else result.notImplemented()
        }
        io.flutter.plugin.common.MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "cn.kingclub.cashier/order-alert").setMethodCallHandler { call, result ->
            if (call.method == "play") {
                try {
                    val tone = android.media.ToneGenerator(android.media.AudioManager.STREAM_MUSIC, 90)
                    tone.startTone(android.media.ToneGenerator.TONE_PROP_ACK, 650)
                    android.os.Handler(mainLooper).postDelayed({ tone.release() }, 900)
                    result.success(null)
                } catch (_: Exception) { result.error("AUDIO_UNAVAILABLE", "Audio unavailable", null) }
            } else result.notImplemented()
        }
        scanner?.dispose()
        scanner = ScannerBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        printerDiscovery?.dispose()
        printerDiscovery = PrinterDiscoveryBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        printerStatus?.dispose()
        printerStatus = PrinterStatusBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        usbPrinterPermission?.dispose()
        usbPrinterPermission = UsbPrinterPermissionBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        usbRasterOutput?.dispose()
        usbRasterOutput = UsbRasterOutputBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        scanner?.dispose()
        scanner = null
        printerDiscovery?.dispose()
        printerDiscovery = null
        printerStatus?.dispose()
        printerStatus = null
        usbPrinterPermission?.dispose()
        usbPrinterPermission = null
        usbRasterOutput?.dispose()
        usbRasterOutput = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

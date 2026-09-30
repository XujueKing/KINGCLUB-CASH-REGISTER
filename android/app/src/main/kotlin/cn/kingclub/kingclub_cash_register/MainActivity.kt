package cn.kingclub.kingclub_cash_register

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var printerDiscovery: PrinterDiscoveryBridge? = null
    private var printerStatus: PrinterStatusBridge? = null
    private var usbPrinterPermission: UsbPrinterPermissionBridge? = null
    private var usbRasterOutput: UsbRasterOutputBridge? = null

    override fun onResume() { super.onResume(); usbRasterOutput?.setForeground(true) }
    override fun onPause() { usbRasterOutput?.setForeground(false); super.onPause() }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        usbRasterOutput?.setForeground(hasFocus)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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

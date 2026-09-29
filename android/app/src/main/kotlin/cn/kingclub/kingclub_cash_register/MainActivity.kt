package cn.kingclub.kingclub_cash_register

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var printerDiscovery: PrinterDiscoveryBridge? = null
    private var printerStatus: PrinterStatusBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        printerDiscovery?.dispose()
        printerDiscovery = PrinterDiscoveryBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        printerStatus?.dispose()
        printerStatus = PrinterStatusBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        printerDiscovery?.dispose()
        printerDiscovery = null
        printerStatus?.dispose()
        printerStatus = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

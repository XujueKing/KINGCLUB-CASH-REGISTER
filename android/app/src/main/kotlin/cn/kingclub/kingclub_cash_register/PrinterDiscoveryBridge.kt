package cn.kingclub.kingclub_cash_register

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbManager
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Discovery only. Never binds, initializes, prints, feeds, cuts or opens drawers. */
class PrinterDiscoveryBridge(context: Context, messenger: BinaryMessenger) {
    private val app = context.applicationContext
    private val channel = MethodChannel(messenger, "cn.kingclub.cashier/printer-discovery")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val busy = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "inspect" || call.arguments != null) {
                result.notImplemented()
            } else if (closed.get()) {
                result.error("PRINTER_DISCOVERY_CLOSED", null, null)
            } else if (!busy.compareAndSet(false, true)) {
                result.error("PRINTER_DISCOVERY_BUSY", null, null)
            } else {
                val delivered = AtomicBoolean(false)
                val timeout = Runnable {
                    if (!closed.get() && delivered.compareAndSet(false, true)) {
                        result.error("PRINTER_DISCOVERY_TIMEOUT", null, null)
                    }
                }
                main.postDelayed(timeout, 2500)
                worker.execute {
                    val observation = runCatching { inspect() }
                    main.post {
                        main.removeCallbacks(timeout)
                        busy.set(false)
                        if (!closed.get() && delivered.compareAndSet(false, true)) {
                            observation.fold(
                                onSuccess = { result.success(it) },
                                onFailure = { result.error("PRINTER_DISCOVERY_FAILED", null, null) }
                            )
                        }
                    }
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun inspect(): Map<String, Any?> {
        val manager = app.packageManager
        val packageName = "woyou.aidlservice.jiuiv5"
        val info = try {
            manager.getPackageInfo(packageName, 0)
        } catch (_: PackageManager.NameNotFoundException) {
            null
        }
        val service = manager.resolveService(
            Intent("woyou.aidlservice.jiuiv5.IWoyouService").setPackage(packageName), 0
        )?.serviceInfo
        val usb = app.getSystemService(Context.USB_SERVICE) as? UsbManager
        val candidates = usb?.deviceList?.values?.count { device ->
            device.deviceClass == UsbConstants.USB_CLASS_PRINTER ||
                (0 until device.interfaceCount).any {
                    device.getInterface(it).interfaceClass == UsbConstants.USB_CLASS_PRINTER
                }
        } ?: 0
        return mapOf(
            "serviceInstalled" to (info != null),
            "serviceEnabled" to (info?.applicationInfo?.enabled == true),
            "serviceVersion" to info?.versionName,
            "serviceResolvable" to (service != null && service.packageName == packageName &&
                service.enabled && service.exported && service.applicationInfo.enabled),
            "usbPrinterCandidates" to candidates
        )
    }

    fun dispose() {
        closed.set(true)
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }
}

package cn.kingclub.kingclub_cash_register

import android.content.Context
import android.content.ComponentName
import android.os.Handler
import android.os.Looper
import com.sunmi.peripheral.printer.InnerPrinterCallback
import com.sunmi.peripheral.printer.InnerPrinterManager
import com.sunmi.peripheral.printer.SunmiPrinterService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Explicit, short-lived read-only binding. No initialization or print commands. */
class PrinterStatusBridge(context: Context, messenger: BinaryMessenger) {
    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val channel = MethodChannel(messenger, "cn.kingclub.cashier/printer-status")
    private val manager = InnerPrinterManager.getInstance()
    private var active: Probe? = null
    private var closed = false

    init {
        channel.setMethodCallHandler { call, result ->
            when {
                call.method != "inspect" || call.arguments != null -> result.notImplemented()
                closed -> result.error("PRINTER_STATUS_CLOSED", null, null)
                active != null -> result.error("PRINTER_STATUS_BUSY", null, null)
                else -> Probe(result).also { active = it }.start()
            }
        }
    }

    private inner class Probe(private val result: MethodChannel.Result) {
        private var bound = false
        private var running = false
        private var delivered = false
        private val cancelled = AtomicBoolean(false)
        private val timeout = Runnable { finish(null, "PRINTER_STATUS_TIMEOUT") }
        private val callback = object : InnerPrinterCallback() {
            override fun onConnected(service: SunmiPrinterService) {
                // ServiceConnection callbacks and lifecycle bookkeeping run on main.
                if (delivered || closed || running) return
                running = true
                worker.execute {
                    // Preserve each raw observation; null means unavailable, never ready.
                    val status = if (cancelled.get()) null else
                        runCatching { service.updatePrinterState() }.getOrNull()
                    val paper = if (cancelled.get()) null else
                        runCatching { service.getPrinterPaper() }.getOrNull()
                    main.post {
                        running = false
                        if (!delivered && !closed) {
                            finish(mapOf("statusCode" to status, "paperCode" to paper), null)
                        }
                        if (active === this@Probe) active = null
                    }
                }
            }

            override fun onDisconnected() { finish(null, "PRINTER_STATUS_DISCONNECTED") }
            override fun onNullBinding(name: ComponentName) {
                finish(null, "PRINTER_STATUS_UNAVAILABLE")
            }
            override fun onBindingDied(name: ComponentName) {
                finish(null, "PRINTER_STATUS_DISCONNECTED")
            }
        }

        fun start() {
            main.postDelayed(timeout, 2500)
            try {
                bound = manager.bindService(app, callback)
                if (!bound) finish(null, "PRINTER_STATUS_UNAVAILABLE")
            } catch (_: Exception) {
                finish(null, "PRINTER_STATUS_UNAVAILABLE")
            }
        }

        fun finish(value: Map<String, Int?>?, error: String?) {
            if (delivered) return
            delivered = true
            cancelled.set(true)
            main.removeCallbacks(timeout)
            if (bound) {
                runCatching { manager.unBindService(app, callback) }
                bound = false
            }
            // A stuck Binder call cannot be cancelled. Keep admission closed until it ends.
            if (!running && active === this) active = null
            if (!closed) {
                if (error == null) result.success(value) else result.error(error, null, null)
            }
        }
    }

    fun dispose() {
        closed = true
        channel.setMethodCallHandler(null)
        active?.finish(null, "PRINTER_STATUS_CLOSED")
        worker.shutdownNow()
    }
}

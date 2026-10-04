package cn.kingclub.kingclub_cash_register

import android.app.Activity
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Handler
import android.os.Build
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** No automatic output. GS v 0 image frames only; no reset, cut or drawer commands. */
class UsbRasterOutputBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val usb = activity.applicationContext.getSystemService(Context.USB_SERVICE) as? UsbManager
    private val channel = MethodChannel(messenger, "cn.kingclub.cashier/usb-raster-output")
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    @Volatile private var foreground = false
    @Volatile private var closed = false
    @Volatile private var generation = 0L
    private val used = mutableSetOf<String>()
    private var registered = false
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            // Conservatively invalidate even if a detached broadcast lacks a device.
            // A reattachment does not resume an old transfer or authorize a retry.
            if (intent?.action == UsbManager.ACTION_USB_DEVICE_DETACHED) generation++
        }
    }

    init {
        if (BuildConfig.USB_RASTER_OUTPUT_ENABLED) {
            registered = runCatching {
                val filter = IntentFilter(UsbManager.ACTION_USB_DEVICE_DETACHED)
                if (Build.VERSION.SDK_INT >= 33) activity.applicationContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
                else @Suppress("DEPRECATION") activity.applicationContext.registerReceiver(receiver, filter)
                true
            }.getOrDefault(false)
        }
        channel.setMethodCallHandler { call, result ->
            when {
                call.method != "send" -> result.notImplemented()
                !BuildConfig.USB_RASTER_OUTPUT_ENABLED -> result.error("USB_OUTPUT_DISABLED", null, null)
                !registered -> result.error("USB_OUTPUT_MONITOR_UNAVAILABLE", null, null)
                closed || !foreground || !activity.hasWindowFocus() || activity.isFinishing || activity.isDestroyed ->
                    result.error("USB_OUTPUT_NOT_FOREGROUND", null, null)
                else -> {
                    val request = runCatching { Request.parse(call.arguments) }.getOrNull()
                    when {
                        request == null -> result.error("USB_OUTPUT_INVALID", null, null)
                        used.contains(request.id) || used.size >= 1000 -> result.error("USB_OUTPUT_REVIEW_REQUIRED", null, null)
                        !busy.compareAndSet(false, true) -> result.error("USB_OUTPUT_BUSY", null, null)
                        else -> {
                            used.add(request.id)
                            val epoch = generation
                            executor.execute {
                                val accepted = runCatching { write(request, epoch) }.onFailure {
                                    val code = it.message
                                    if (code != null && code.matches(Regex("^[A-Z_]{1,80}$"))) {
                                        android.util.Log.i("KingPrinter", code)
                                    }
                                }.getOrNull()
                                main.post {
                                    busy.set(false)
                                    if (accepted == null) result.error("USB_OUTPUT_UNKNOWN", null, null)
                                    else result.success(mapOf("attemptId" to request.id, "acceptedBytes" to accepted))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    fun setForeground(value: Boolean) { foreground = value; if (!value) generation++ }
    fun dispose() {
        closed = true; foreground = false; generation++
        channel.setMethodCallHandler(null)
        if (registered) runCatching { activity.applicationContext.unregisterReceiver(receiver) }
        registered = false
        executor.shutdown() // In-flight bounded transfer releases its own connection.
    }
    private fun write(request: Request, epoch: Long): Int {
        fun active() = !closed && foreground && generation == epoch
        require(active())
        val manager = usb ?: error("unavailable")
        val device = manager.deviceList.values.singleOrNull { request.matches(it) } ?: error("changed")
        require(manager.hasPermission(device))
        val iface = (0 until device.interfaceCount).map { device.getInterface(it) }.single {
            it.id == request.n.getValue("interfaceId") && it.alternateSetting == request.n.getValue("alternate")
        }
        // Keep the selected alternate setting. The installed XP-80U is bound
        // to Linux usblp; Android must detach that kernel driver to claim it.
        require(iface.alternateSetting == 0)
        val endpoint = (0 until iface.endpointCount).map { iface.getEndpoint(it) }.single {
            it.address == request.n.getValue("endpointAddress")
        }
        var connection: UsbDeviceConnection? = null
        var claimed: UsbInterface? = null
        try {
            val current = manager.openDevice(device) ?: error("open_failed")
            connection = current
            require(active())
            val installedPrinter = device.vendorId == 1155 && device.productId == 22339
            check(current.claimInterface(iface, installedPrinter)) { "USB_CLAIM_FAILED" }
            claimed = iface
            val deadline = SystemClock.elapsedRealtime() + 20000
            var offset = 0
            while (offset < request.bytes.size) {
                require(active() && SystemClock.elapsedRealtime() < deadline)
                require(manager.hasPermission(device) && manager.deviceList.values.any {
                    it.deviceName == device.deviceName && request.matches(it)
                })
                val count = minOf(4096, request.bytes.size - offset)
                val remaining = (deadline - SystemClock.elapsedRealtime()).coerceAtMost(1000).toInt()
                require(remaining > 0)
                val sent = current.bulkTransfer(endpoint, request.bytes, offset, count, remaining)
                if (sent != count) error("USB_PARTIAL_OR_UNKNOWN") // Never resend a chunk.
                offset += sent
            }
            require(active())
            return offset // Host acceptance only, not physical paper completion.
        } finally {
            claimed?.let { selected -> runCatching { connection?.releaseInterface(selected) } }
            runCatching { connection?.close() }
        }
    }
    private data class Request(val id: String, val n: Map<String, Int>, val bytes: ByteArray) {
        fun matches(d: UsbDevice): Boolean = d.deviceId == n["deviceId"] && d.vendorId == n["vendorId"] &&
            d.productId == n["productId"] && d.deviceClass == n["deviceClass"] &&
            (0 until d.interfaceCount).any { index ->
                val i = d.getInterface(index)
                i.id == n["interfaceId"] && i.alternateSetting == n["alternate"] && i.interfaceClass == 7 &&
                    i.interfaceSubclass == 1 && i.interfaceProtocol == n["protocol"] &&
                    (0 until i.endpointCount).any { e -> val ep = i.getEndpoint(e)
                        ep.address == n["endpointAddress"] && ep.type == 2 && ep.maxPacketSize == n["maxPacketSize"] }
            }
        companion object {
            fun parse(raw: Any?): Request {
                val map = raw as? Map<*, *> ?: error("invalid")
                val limits = mapOf("deviceId" to Int.MAX_VALUE, "vendorId" to 65535, "productId" to 65535,
                    "deviceClass" to 255, "interfaceId" to 255, "alternate" to 0, "protocol" to 2,
                    "endpointAddress" to 15, "maxPacketSize" to 65535)
                require(map.keys == limits.keys + setOf("attemptId", "bytes"))
                val id = map["attemptId"] as? String ?: error("invalid")
                require(id.matches(Regex("[0-9a-f]{32}")))
                val n = limits.mapValues { (key, max) ->
                    val v = map[key] as? Int ?: error("invalid"); require(v in 0..max); v
                }
                require(n.getValue("protocol") in 1..2 && n.getValue("endpointAddress") > 0 && n.getValue("maxPacketSize") > 0)
                val bytes = (map["bytes"] as? ByteArray)?.copyOf() ?: error("invalid")
                UsbRasterFrames.validate(bytes)
                return Request(id, n, bytes)
            }
        }
    }
}

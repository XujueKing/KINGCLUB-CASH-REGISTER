package cn.kingclub.kingclub_cash_register

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/** Requests OS permission only. Never opens, claims, resets or writes a USB device. */
class UsbPrinterPermissionBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val app = activity.applicationContext
    private val usb = app.getSystemService(Context.USB_SERVICE) as? UsbManager
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "cn.kingclub.cashier/usb-printer-permission")
    private var pending: Request? = null
    private var closed = false

    init {
        channel.setMethodCallHandler { call, result ->
            when {
                call.method == "cancel" && call.arguments is String -> {
                    if (pending?.requestId == call.arguments) pending?.finish(null, "USB_PERMISSION_CANCELLED")
                    result.success(null)
                }
                call.method != "request" -> result.notImplemented()
                closed -> result.error("USB_PERMISSION_CLOSED", null, null)
                pending != null -> result.error("USB_PERMISSION_BUSY", null, null)
                !activity.hasWindowFocus() || activity.isFinishing || activity.isDestroyed ->
                    result.error("USB_PERMISSION_NOT_FOREGROUND", null, null)
                else -> {
                    val selection = runCatching { Selection.parse(call.arguments) }.getOrNull()
                    if (selection == null) result.error("USB_PERMISSION_INVALID", null, null)
                    else Request(selection, result).also { pending = it }.start()
                }
            }
        }
    }

    private data class Selection(val requestId: String, val numbers: Map<String, Int>) {
        companion object {
            private val limits = mapOf("deviceId" to Int.MAX_VALUE, "vendorId" to 65535,
                "productId" to 65535, "deviceClass" to 255, "interfaceId" to 255,
                "alternate" to 255, "protocol" to 2, "endpointAddress" to 15,
                "maxPacketSize" to 65535)
            fun parse(raw: Any?): Selection {
                val map = raw as? Map<*, *> ?: error("invalid")
                require(map.keys == limits.keys + "requestId")
                val id = map["requestId"] as? String ?: error("invalid")
                require(id.matches(Regex("[a-f0-9]{32}")))
                val values = limits.mapValues { (key, max) ->
                    val value = map[key] as? Int ?: error("invalid")
                    require(value in 0..max)
                    value
                }
                require(values.getValue("protocol") in 1..2)
                require(values.getValue("endpointAddress") > 0 && values.getValue("maxPacketSize") > 0)
                return Selection(id, values)
            }
        }
        fun matches(device: UsbDevice): Boolean {
            val v = numbers
            if (device.deviceId != v["deviceId"] || device.vendorId != v["vendorId"] ||
                device.productId != v["productId"] || device.deviceClass != v["deviceClass"]) return false
            return (0 until device.interfaceCount).any { index ->
                val iface = device.getInterface(index)
                iface.id == v["interfaceId"] && iface.alternateSetting == v["alternate"] &&
                    iface.interfaceClass == 7 && iface.interfaceSubclass == 1 &&
                    iface.interfaceProtocol == v["protocol"] &&
                    (0 until iface.endpointCount).any { endpointIndex ->
                        val endpoint = iface.getEndpoint(endpointIndex)
                        endpoint.address == v["endpointAddress"] && endpoint.type == 2 &&
                            endpoint.maxPacketSize == v["maxPacketSize"]
                    }
            }
        }
    }

    private inner class Request(private val selection: Selection, private val result: MethodChannel.Result) {
        val requestId = selection.requestId
        private val action = "${app.packageName}.USB_PERMISSION.${UUID.randomUUID()}"
        private var registered = false
        private var delivered = false
        private var intent: PendingIntent? = null
        private var deviceName: String? = null // Kept only in memory; never returned or persisted.
        private val timeout = Runnable { finish(null, "USB_PERMISSION_TIMEOUT") }
        private val receiver = object : BroadcastReceiver() {
            @Suppress("DEPRECATION")
            override fun onReceive(context: Context, broadcast: Intent) {
                if (delivered || closed) return
                if (broadcast.action == UsbManager.ACTION_USB_DEVICE_DETACHED) {
                    val detached = broadcast.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                    if (detached?.deviceName == deviceName) finish(null, "USB_PERMISSION_DETACHED")
                } else if (broadcast.action == action) {
                    // Do not trust broadcast extras. Re-read OS permission and the exact selection.
                    runCatching {
                        val device = current() ?: return@runCatching finish(null, "USB_PERMISSION_CHANGED")
                        finish(usb?.hasPermission(device) == true, null)
                    }.onFailure { finish(null, "USB_PERMISSION_FAILED") }
                }
            }
        }

        private fun current(): UsbDevice? = usb?.deviceList?.values?.singleOrNull {
            selection.matches(it) && (deviceName == null || it.deviceName == deviceName)
        }

        @Suppress("DEPRECATION")
        fun start() {
            try {
                val device = current() ?: return finish(null, "USB_PERMISSION_CHANGED")
                deviceName = device.deviceName
                if (usb?.hasPermission(device) == true) return finish(true, null)
                val filter = IntentFilter(action).apply { addAction(UsbManager.ACTION_USB_DEVICE_DETACHED) }
                if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
                else app.registerReceiver(receiver, filter)
                registered = true
                // Immutable: all routing comes from our random action/package, no fill-in extras needed.
                intent = PendingIntent.getBroadcast(app, 0, Intent(action).setPackage(app.packageName),
                    PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE)
                main.postDelayed(timeout, 60000)
                usb?.requestPermission(device, intent!!)
            } catch (_: Exception) {
                finish(null, "USB_PERMISSION_FAILED")
            }
        }

        fun finish(granted: Boolean?, error: String?) {
            if (delivered) return
            delivered = true
            main.removeCallbacks(timeout)
            intent?.cancel()
            if (registered) runCatching { app.unregisterReceiver(receiver) }
            registered = false
            if (pending === this) pending = null
            if (!closed) {
                if (error != null) result.error(error, null, null)
                else result.success(mapOf("requestId" to requestId, "granted" to granted))
            }
        }
    }

    fun dispose() {
        closed = true
        channel.setMethodCallHandler(null)
        pending?.finish(null, "USB_PERMISSION_CLOSED")
    }
}

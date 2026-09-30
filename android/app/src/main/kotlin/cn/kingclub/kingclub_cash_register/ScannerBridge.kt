package cn.kingclub.kingclub_cash_register

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/** SUNMI scanner output is untrusted input, never an authorization or receipt. */
class ScannerBridge(private val activity: Activity, messenger: BinaryMessenger) : EventChannel.StreamHandler {
    private val channel = EventChannel(messenger, "kingclub/scanner")
    private var sink: EventChannel.EventSink? = null
    private var foreground = false
    private var registered = false
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (!foreground || intent?.action != ACTION) return
            val code = intent.getStringExtra("data")?.trim() ?: return
            if (code.isNotEmpty() && code.length <= 512) sink?.success(code)
        }
    }

    init { channel.setStreamHandler(this) }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events; update() }
    override fun onCancel(arguments: Any?) { sink = null; update() }
    fun setForeground(value: Boolean) { foreground = value; update() }
    @Suppress("DEPRECATION")
    private fun update() {
        val wanted = foreground && sink != null
        if (wanted && !registered) {
            // The vendor scanner is a separate system app. The server validates
            // every scanned member token; broadcasts confer no extra authority.
            if (Build.VERSION.SDK_INT >= 33) activity.registerReceiver(receiver, IntentFilter(ACTION), Context.RECEIVER_EXPORTED)
            else activity.registerReceiver(receiver, IntentFilter(ACTION))
            registered = true
        } else if (!wanted && registered) {
            activity.unregisterReceiver(receiver)
            registered = false
        }
    }
    fun dispose() { sink = null; update(); channel.setStreamHandler(null) }
    private companion object { const val ACTION = "com.sunmi.scanner.ACTION_DATA_CODE_RECEIVED" }
}

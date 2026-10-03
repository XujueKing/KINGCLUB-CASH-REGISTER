package cn.kingclub.kingclub_cash_register

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/** SUNMI scanner output is untrusted input, never an authorization or receipt. */
class ScannerBridge(private val activity: Activity, messenger: BinaryMessenger) : EventChannel.StreamHandler {
    private val channel = EventChannel(messenger, "kingclub/scanner")
    private var sink: EventChannel.EventSink? = null
    private var foreground = false
    private var registered = false
    private val handler = Handler(Looper.getMainLooper())
    private val buffer = StringBuilder()
    private var lastKeyAt = 0L
    private var lastDevice = -1
    private var lastCode: String? = null
    private var lastCodeAt = 0L
    private val finishScan = Runnable { flush() }
    private fun clearBuffer() { handler.removeCallbacks(finishScan); buffer.setLength(0); lastDevice = -1 }
    private fun emit(code: String) {
        if (!foreground || sink == null || code.isBlank() || code.length > 512) return
        val now = SystemClock.uptimeMillis()
        if (code == lastCode && now - lastCodeAt < 500) return
        lastCode = code; lastCodeAt = now
        sink?.success(code)
        handler.postDelayed({ if (lastCodeAt == now) lastCode = null }, 500)
    }
    private fun flush() { val code = buffer.toString(); clearBuffer(); emit(code) }
    /** Capture external USB HID input before Flutter focus dispatch, only while a scan screen listens. */
    fun onKeyEvent(event: KeyEvent): Boolean {
        if (!foreground || sink == null || event.device?.isExternal != true) return false
        val end = event.keyCode == KeyEvent.KEYCODE_ENTER || event.keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER || event.keyCode == KeyEvent.KEYCODE_TAB
        val char = event.unicodeChar
        if (!end && (char < 32 || char > 126)) return false
        if (event.action != KeyEvent.ACTION_DOWN) return event.action == KeyEvent.ACTION_UP
        if (event.repeatCount != 0) return true
        val now = SystemClock.uptimeMillis()
        if (lastDevice != event.deviceId || now - lastKeyAt > 250) clearBuffer()
        lastDevice = event.deviceId; lastKeyAt = now
        if (end) { flush(); return true }
        if (buffer.length >= 512) { clearBuffer(); return true }
        buffer.append(char.toChar())
        handler.removeCallbacks(finishScan)
        handler.postDelayed(finishScan, 250)
        return true
    }
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (!foreground || intent?.action != ACTION) return
            val code = intent.getStringExtra("data")?.trim() ?: return
            emit(code)
        }
    }

    init { channel.setStreamHandler(this) }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events; update() }
    override fun onCancel(arguments: Any?) { sink = null; clearBuffer(); lastCode = null; update() }
    fun setForeground(value: Boolean) { foreground = value; if (!value) { clearBuffer(); lastCode = null }; update() }
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
    fun dispose() { sink = null; clearBuffer(); handler.removeCallbacksAndMessages(null); update(); channel.setStreamHandler(null) }
    private companion object { const val ACTION = "com.sunmi.scanner.ACTION_DATA_CODE_RECEIVED" }
}

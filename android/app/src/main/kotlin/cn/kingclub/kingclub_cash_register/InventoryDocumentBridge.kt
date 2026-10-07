package cn.kingclub.kingclub_cash_register

import android.app.Activity
import android.content.Intent
import android.provider.OpenableColumns
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** System document chooser; no storage permission or guessed local paths. */
class InventoryDocumentBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "cn.kingclub.cashier/inventory-document")
    private var pending: MethodChannel.Result? = null
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "choose") result.notImplemented()
            else if (pending != null) result.error("DOCUMENT_BUSY", "Choose one document at a time", null)
            else {
                pending = result
                try {
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/png", "image/jpeg", "application/pdf"))
                    }
                    activity.startActivityForResult(intent, REQUEST)
                } catch (_: Exception) { pending = null; result.error("DOCUMENT_UNAVAILABLE", "Document chooser unavailable", null) }
            }
        }
    }
    fun onActivityResult(request: Int, resultCode: Int, data: Intent?): Boolean {
        if (request != REQUEST) return false
        val result = pending ?: return true
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return true }
        try {
            val mime = activity.contentResolver.getType(uri)
            if (mime !in listOf("image/png", "image/jpeg", "application/pdf")) throw IllegalArgumentException()
            var name = "purchase-document"
            activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) name = it.getString(0).take(120)
            }
            val bytes = activity.contentResolver.openInputStream(uri)?.use { it.readBytesLimited(1024 * 1024) } ?: throw IllegalArgumentException()
            result.success(mapOf("name" to name, "contentType" to mime, "base64" to Base64.encodeToString(bytes, Base64.NO_WRAP)))
        } catch (_: Exception) { result.error("DOCUMENT_INVALID", "Select a PNG, JPEG or PDF up to 1 MB", null) }
        return true
    }
    private fun java.io.InputStream.readBytesLimited(limit: Int): ByteArray {
        val buffer = java.io.ByteArrayOutputStream()
        val chunk = ByteArray(8192)
        while (true) {
            val n = read(chunk)
            if (n < 0) break
            if (buffer.size() + n > limit) throw IllegalArgumentException()
            buffer.write(chunk, 0, n)
        }
        return buffer.toByteArray()
    }
    fun dispose() { channel.setMethodCallHandler(null); pending?.error("DOCUMENT_CLOSED", "Document chooser closed", null); pending = null }
    companion object { private const val REQUEST = 6718 }
}

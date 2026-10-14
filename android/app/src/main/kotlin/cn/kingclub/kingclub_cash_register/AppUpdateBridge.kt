package cn.kingclub.kingclub_cash_register

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** At most one bounded stream; never materialize an APK in the Flutter/JSON heap. */
class AppUpdateBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "cn.kingclub.cashier/app-update")
    private val worker = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    private val busy = AtomicBoolean(false)
    @Volatile private var disposed = false
    @Volatile private var foreground = false
    @Volatile private var connection: HttpURLConnection? = null
    private val directory = File(activity.cacheDir, "cashier-update")
    private val apk = File(directory, "update.apk")
    private val partial = File(directory, "update.part")
    private var ready: JSONObject? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> {
                    val info = installed()
                    result.success(mapOf("versionName" to info.versionName, "versionCode" to version(info)))
                }
                "check" -> {
                    val url = call.argument<String>("url") ?: ""
                    run(result) { check(url) }
                }
                "install" -> run(result) {
                    val manifest = ready ?: error("NOT_READY")
                    verify(apk, manifest)
                    handler.post {
                        if (disposed) return@post
                        if (!foreground) {
                            result.error("INSTALL_NOT_FOREGROUND", "Return to the cashier before installing", null)
                            return@post
                        }
                        try {
                            if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
                                activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:${activity.packageName}")))
                                result.success(mapOf("status" to "permission"))
                            } else {
                                val uri = FileProvider.getUriForFile(activity,
                                    "${activity.packageName}.updates", apk)
                                activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, "application/vnd.android.package-archive")
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                })
                                result.success(mapOf("status" to "installer"))
                            }
                        } catch (_: Exception) { result.error("INSTALL_UNAVAILABLE", "Installer unavailable", null) }
                    }
                    null // Installation result is returned only from the main thread above.
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun run(result: MethodChannel.Result, action: () -> Map<String, Any?>?) {
        if (!busy.compareAndSet(false, true)) {
            result.error("UPDATE_BUSY", "Update in progress", null); return
        }
        worker.execute {
            try {
                val value = action()
                if (value != null) handler.post { if (!disposed) result.success(value) }
            } catch (_: Exception) {
                partial.delete()
                handler.post { if (!disposed) result.error("UPDATE_FAILED", "Update could not be verified or downloaded", null) }
            } finally { busy.set(false) }
        }
    }

    @Suppress("DEPRECATION")
    private fun installed(): PackageInfo = activity.packageManager.getPackageInfo(activity.packageName, signatureFlags())
    private fun signatureFlags() = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    @Suppress("DEPRECATION")
    private fun version(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> =
        (if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures)
            ?.map { digest(it.toByteArray()) }?.toSet() ?: emptySet()

    private fun transfer(url: String, limit: Long, write: (ByteArray, Int) -> Unit): Long {
        val conn = URL(url).openConnection() as HttpURLConnection
        connection = conn
        try {
            conn.instanceFollowRedirects = false
            conn.connectTimeout = 15000
            conn.readTimeout = 20000
            conn.useCaches = false
            conn.setRequestProperty("Accept-Encoding", "identity")
            require(conn.responseCode == 200)
            require(conn.contentLengthLong <= limit)
            val deadline = System.nanoTime() + 10L * 60 * 1_000_000_000
            var count = 0L
            conn.inputStream.use { input ->
                val buffer = ByteArray(32 * 1024)
                while (true) {
                    check(!disposed && !Thread.currentThread().isInterrupted)
                    require(System.nanoTime() < deadline)
                    val n = input.read(buffer)
                    if (n < 0) break
                    count += n
                    require(count <= limit)
                    write(buffer, n)
                }
            }
            return count
        } finally { conn.disconnect(); connection = null }
    }

    private fun check(manifestUrl: String): Map<String, Any?> {
        // Validate the transport before opening a connection, including when there is no release.
        UpdatePolicy.validateUrl(manifestUrl, manifestUrl.substringBeforeLast('/') + "/probe.apk")
        val output = java.io.ByteArrayOutputStream()
        transfer(manifestUrl, UpdatePolicy.MAX_MANIFEST_BYTES.toLong()) { bytes, n -> output.write(bytes, 0, n) }
        val manifest = JSONObject(output.toString("UTF-8"))
        require(manifest.getInt("schemaVersion") == 1)
        require(manifest.getString("packageName") == activity.packageName)
        require(manifest.getString("abi") in Build.SUPPORTED_ABIS)
        val current = installed()
        val nextVersion = manifest.getLong("versionCode")
        if (nextVersion <= version(current)) {
            ready = null
            apk.delete(); partial.delete()
            return mapOf("status" to "current")
        }
        val size = manifest.getLong("bytes")
        val hash = manifest.getString("sha256")
        UpdatePolicy.validateMetadata(size, hash, nextVersion, version(current))
        val url = manifest.getString("url")
        UpdatePolicy.validateUrl(manifestUrl, url)
        ready = null
        directory.mkdirs()
        partial.delete()
        if (apk.exists()) {
            try { verify(apk, manifest); ready = manifest; return readyResult(manifest) }
            catch (_: Exception) { apk.delete() }
        }
        require(StatFs(directory.absolutePath).availableBytes > size * 2 + 32L * 1024 * 1024)
        progress(0)
        var bytesRead = 0L
        var lastPercent = -1
        partial.outputStream().use { out ->
            val count = transfer(url, size) { buffer, n ->
                out.write(buffer, 0, n)
                bytesRead += n
                val percent = (bytesRead * 100 / size).toInt()
                if (percent >= lastPercent + 5) { lastPercent = percent; progress(percent) }
            }
            require(count == size)
        }
        verify(partial, manifest)
        require(partial.renameTo(apk))
        ready = manifest
        return readyResult(manifest)
    }

    private fun readyResult(manifest: JSONObject): Map<String, Any?> = mapOf(
        "status" to "ready", "versionName" to manifest.getString("versionName").take(64),
        "notes" to manifest.optString("notes").take(1200))

    private fun progress(percent: Int) = handler.post {
        if (!disposed) channel.invokeMethod("progress", percent)
    }

    @Suppress("DEPRECATION")
    private fun verify(file: File, manifest: JSONObject) {
        require(file.length() == manifest.getLong("bytes"))
        val sha = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(32 * 1024)
            while (true) { val n = input.read(buffer); if (n < 0) break; sha.update(buffer, 0, n) }
        }
        require(sha.digest().joinToString("") { "%02x".format(it) } == manifest.getString("sha256"))
        val candidate = activity.packageManager.getPackageArchiveInfo(file.absolutePath, signatureFlags())
            ?: error("INVALID_APK")
        val current = installed()
        require((candidate.applicationInfo?.minSdkVersion ?: Int.MAX_VALUE) <= Build.VERSION.SDK_INT)
        UpdatePolicy.validateIdentity(activity.packageName, candidate.packageName,
            manifest.getLong("versionCode"), version(candidate), version(current), signers(current), signers(candidate))
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        connection?.disconnect()
        worker.shutdownNow()
    }

    fun setForeground(value: Boolean) { foreground = value }
}

package cn.kingclub.kingclub_cash_register

import java.net.URI

/** Pure validation shared by the downloader and install-time recheck. */
object UpdatePolicy {
    const val MAX_APK_BYTES = 100L * 1024 * 1024
    const val MAX_MANIFEST_BYTES = 16 * 1024

    fun validateUrl(manifest: String, apk: String) {
        val base = URI(manifest)
        val target = URI(apk)
        require(base.scheme == "https" && target.scheme == "https")
        require(!base.host.isNullOrEmpty() && base.host == target.host && base.port == target.port)
        require(base.userInfo == null && target.userInfo == null)
        require(base.query == null && target.query == null && base.fragment == null && target.fragment == null)
        require(base.path.endsWith("/stable.json"))
        val prefix = base.path.substringBeforeLast('/') + "/"
        require(target.path.startsWith(prefix) && target.normalize() == target)
        require(target.path.removePrefix(prefix).matches(Regex("[a-zA-Z0-9._-]+\\.apk")))
    }

    fun validateMetadata(bytes: Long, hash: String, version: Long, installed: Long) {
        require(bytes in 1..MAX_APK_BYTES)
        require(hash.matches(Regex("[a-f0-9]{64}")))
        require(version > installed)
    }

    fun validateIdentity(expectedPackage: String, actualPackage: String, expectedVersion: Long,
                         actualVersion: Long, installedVersion: Long,
                         installedSigners: Set<String>, apkSigners: Set<String>) {
        require(expectedPackage == actualPackage)
        require(actualVersion == expectedVersion && actualVersion > installedVersion)
        require(installedSigners.isNotEmpty() && installedSigners == apkSigners)
    }
}

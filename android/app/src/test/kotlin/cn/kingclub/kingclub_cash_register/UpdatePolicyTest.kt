package cn.kingclub.kingclub_cash_register

import org.junit.Assert.assertThrows
import org.junit.Test

class UpdatePolicyTest {
    private val manifest = "https://updates.example.test/kingclub-updates/cashier/stable.json"
    @Test fun acceptsSameOriginRelease() {
        UpdatePolicy.validateUrl(manifest, "https://updates.example.test/kingclub-updates/cashier/cashier-1003.apk")
        UpdatePolicy.validateMetadata(23_000_000, "a".repeat(64), 1003, 1002)
        UpdatePolicy.validateIdentity("app.cashier", "app.cashier", 1003, 1003, 1002, setOf("original"), setOf("original"))
    }
    @Test fun rejectsForeignAndUnsafeUrls() {
        for (url in listOf("http://updates.example.test/kingclub-updates/cashier/app.apk",
            "https://evil.example.test/kingclub-updates/cashier/app.apk",
            "https://updates.example.test/kingclub-updates/cashier/../app.apk",
            "https://updates.example.test/kingclub-updates/cashier/%2e%2e/app.apk",
            "https://updates.example.test/kingclub-updates/cashier/app.apk?token=secret",
            "https://user@updates.example.test/kingclub-updates/cashier/app.apk")) {
            assertThrows(IllegalArgumentException::class.java) { UpdatePolicy.validateUrl(manifest, url) }
        }
    }
    @Test fun rejectsOversizedTruncatedMetadataAndDowngrades() {
        for (size in listOf(0L, -1L, UpdatePolicy.MAX_APK_BYTES + 1)) {
            assertThrows(IllegalArgumentException::class.java) { UpdatePolicy.validateMetadata(size, "a".repeat(64), 1003, 1002) }
        }
        assertThrows(IllegalArgumentException::class.java) { UpdatePolicy.validateMetadata(100, "abc", 1003, 1002) }
        assertThrows(IllegalArgumentException::class.java) { UpdatePolicy.validateMetadata(100, "a".repeat(64), 1002, 1002) }
    }
    @Test fun rejectsDifferentCertificatePackageAndVersion() {
        assertThrows(IllegalArgumentException::class.java) { UpdatePolicy.validateIdentity("a", "a", 1003, 1003, 1002, setOf("original"), setOf("debug")) }
        assertThrows(IllegalArgumentException::class.java) { UpdatePolicy.validateIdentity("a", "b", 1003, 1003, 1002, setOf("original"), setOf("original")) }
        assertThrows(IllegalArgumentException::class.java) { UpdatePolicy.validateIdentity("a", "a", 1003, 1002, 1002, setOf("original"), setOf("original")) }
        assertThrows(IllegalArgumentException::class.java) { UpdatePolicy.validateIdentity("a", "a", 1003, 1003, 1002, emptySet(), emptySet()) }
    }
}

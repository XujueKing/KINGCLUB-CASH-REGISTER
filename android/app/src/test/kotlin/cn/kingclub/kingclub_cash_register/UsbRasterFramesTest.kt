package cn.kingclub.kingclub_cash_register

import org.junit.Assert.assertThrows
import org.junit.Test

class UsbRasterFramesTest {
    private fun frame(width: Int = 1, rows: Int = 1): ByteArray =
        byteArrayOf(29, 118, 48, 0, (width and 255).toByte(), (width shr 8).toByte(),
            (rows and 255).toByte(), (rows shr 8).toByte()) + ByteArray(width * rows)
    private fun rejected(bytes: ByteArray) {
        assertThrows(IllegalArgumentException::class.java) { UsbRasterFrames.validate(bytes) }
    }
    @Test fun acceptsExactFrameAndMultipleStripes() {
        UsbRasterFrames.validate(frame())
        UsbRasterFrames.validate(frame(72, 256) + frame(72, 1))
        UsbRasterFrames.validate((1..16).fold(byteArrayOf()) { all, _ -> all + frame(72, 256) })
    }
    @Test fun imageBytesAreNotInterpretedAsExtraCommands() {
        val bytes = frame(8, 1)
        byteArrayOf(27, 112, 0, 29, 86, 0, 27, 64).copyInto(bytes, 8)
        UsbRasterFrames.validate(bytes)
    }
    @Test fun rejectsExtraCommandsTruncationAndWrongMode() {
        rejected(frame() + byteArrayOf(29, 86, 0))
        rejected(frame().copyOf(8))
        rejected(frame().also { it[3] = 1 })
        rejected(frame().also { it[0] = 27 })
        rejected(byteArrayOf())
    }
    @Test fun rejectsInvalidDimensionsAndInconsistentWidth() {
        rejected(frame(73, 1))
        rejected(frame(1, 257))
        rejected(frame(1, 1) + frame(2, 1))
        rejected(frame().also { it[4] = 0 })
        rejected(frame().also { it[6] = 0 })
        rejected((1..17).fold(byteArrayOf()) { all, _ -> all + frame(1, 256) })
    }
}

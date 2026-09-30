package cn.kingclub.kingclub_cash_register

/** Validates frame boundaries, never searches image bytes for command values. */
internal object UsbRasterFrames {
    fun validate(bytes: ByteArray) {
        require(bytes.size in 9..1000000)
        var offset = 0
        var width = -1
        var totalRows = 0
        fun b(i: Int) = bytes[i].toInt() and 255
        while (offset < bytes.size) {
            require(bytes.size - offset >= 8)
            require(b(offset) == 29 && b(offset + 1) == 118 && b(offset + 2) == 48 && b(offset + 3) == 0)
            val w = b(offset + 4) + 256 * b(offset + 5)
            val rows = b(offset + 6) + 256 * b(offset + 7)
            require(w in 1..72 && rows in 1..256)
            if (width < 0) width = w else require(width == w)
            totalRows += rows
            require(totalRows <= 4096)
            offset += 8 + w * rows
            require(offset <= bytes.size)
        }
    }
}

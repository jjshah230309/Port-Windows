/// Minimal PNG writer (uncompressed "stored" deflate blocks), for save-state thumbnails and screenshots.
/// Files are larger than a compressing encoder would make, which is fine for 160x144 images.
public enum PNGEncoder {
    /// Encodes 32-bit BGRA pixels (as emulator cores produce them) into an RGB PNG.
    public static func encode(bgra pixels: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> [UInt8] {
        var raw: [UInt8] = []
        raw.reserveCapacity((width * 3 + 1) * height)
        for y in 0..<height {
            raw.append(0)       // filter type: none
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                raw.append(pixels[i + 2]); raw.append(pixels[i + 1]); raw.append(pixels[i])
            }
        }
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var ihdr: [UInt8] = []
        ihdr += be32(UInt32(width)); ihdr += be32(UInt32(height))
        ihdr += [8, 2, 0, 0, 0]          // 8-bit, RGB, deflate, no filter, no interlace
        png += chunk("IHDR", ihdr)
        png += chunk("IDAT", zlibStored(raw))
        png += chunk("IEND", [])
        return png
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        var crc = CRC32()
        crc.update(typeBytes)
        crc.update(data)
        return be32(UInt32(data.count)) + typeBytes + data + be32(crc.value)
    }

    private static func zlibStored(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let n = min(65_535, data.count - offset)
            let final: UInt8 = offset + n >= data.count ? 1 : 0
            out.append(final)
            out.append(UInt8(n & 0xFF)); out.append(UInt8(n >> 8))
            out.append(UInt8(~n & 0xFF)); out.append(UInt8((~n >> 8) & 0xFF))
            out += data[offset..<(offset + n)]
            offset += n
        } while offset < data.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
        out += be32(b << 16 | a)
        return out
    }
}

import Foundation
import MachO

/// Builds a minimal thin arm64 Mach-O on disk: one `__TEXT` segment covering the
/// whole file, with arbitrary 32-bit words planted at chosen file offsets. Enough
/// for `RevokeLocator` (segment walk + word scan) and `Patcher` (VA→offset + write).
enum MachOFixture {
    static let baseVA: UInt64 = 0x1_0000_0000
    static let headerSize = 32 + 72

    static func write(size: Int, words: [Int: UInt32]) throws -> URL {
        precondition(size > headerSize && size % 4 == 0)
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            func put32(_ v: UInt32, _ at: Int) { raw.storeBytes(of: v.littleEndian, toByteOffset: at, as: UInt32.self) }
            func put64(_ v: UInt64, _ at: Int) { raw.storeBytes(of: v.littleEndian, toByteOffset: at, as: UInt64.self) }
            // mach_header_64
            put32(MH_MAGIC_64, 0)
            put32(UInt32(CPU_TYPE_ARM64), 4)
            put32(0, 8)                 // cpusubtype
            put32(UInt32(MH_DYLIB), 12)
            put32(1, 16)                // ncmds
            put32(72, 20)               // sizeofcmds
            put32(0, 24)                // flags
            put32(0, 28)                // reserved
            // segment_command_64 @32
            put32(UInt32(LC_SEGMENT_64), 32)
            put32(72, 36)
            let name = Array("__TEXT".utf8)
            for (i, b) in name.enumerated() { raw.storeBytes(of: b, toByteOffset: 40 + i, as: UInt8.self) }
            put64(baseVA, 56)           // vmaddr
            put64(UInt64(size), 64)     // vmsize
            put64(0, 72)                // fileoff
            put64(UInt64(size), 80)     // filesize
            put32(5, 88); put32(5, 92)  // maxprot / initprot
            put32(0, 96); put32(0, 100) // nsects / flags
            for (offset, word) in words {
                precondition(offset >= headerSize && offset + 4 <= size && offset % 4 == 0)
                put32(word, offset)
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechattweak-fixture-\(UUID().uuidString).dylib")
        try data.write(to: url)
        return url
    }

    static func word(at offset: Int, in url: URL) throws -> UInt32 {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }

    /// config.json spelling (big-endian hex) → little-endian instruction word.
    static func word(_ hex: String) -> UInt32 {
        let bytes = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[s..<hex.index(s, offsetBy: 2)], radix: 16)!
        }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }
}

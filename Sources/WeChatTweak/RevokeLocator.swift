//
//  RevokeLocator.swift
//  WeChatTweak
//
//  Locates the anti-revoke patch points inside `wechat.dylib` by scanning for a
//  build-invariant code signature, so a build that is not yet curated in
//  config.json can still be patched with `--auto-locate`.
//
//  The signature is the same one `tools/locate_revoke.py` uses: the entry `E` of
//  `parseRevokeXML` satisfies
//      E+0x270 == `cbz w0, SKIP`               (E00F0034)  ← silent patch point
//      E+0xA04 == `str <Xt>,[x19,#0x168]`      (60B600F9)  ← keeptip patch point
//  Both anchors must hold and the hit must be unique, which is what makes the
//  keeptip address derivable rather than hand-maintained: keeptip = silent + 0x794.
//

import Foundation
import MachO

struct RevokeLocator {
    enum Error: LocalizedError {
        case notMachO
        case noArm64Slice
        case noHit
        case ambiguous(count: Int, vas: [UInt64])

        var errorDescription: String? {
            switch self {
            case .notMachO:
                return "auto-locate: not a 64-bit Mach-O"
            case .noArm64Slice:
                return "auto-locate: no arm64 slice in this binary"
            case .noHit:
                return "auto-locate: signature not found — this build changed the parseRevokeXML layout. Locate the patch point manually (see README) instead of --auto-locate."
            case let .ambiguous(count, vas):
                let list = vas.map { String(format: "0x%llx", $0) }.joined(separator: ", ")
                return "auto-locate: signature matched \(count) sites (\(list)) — ambiguous, refusing to guess. Locate manually (see README)."
            }
        }
    }

    /// `cbz w0, SKIP` — the silent patch point's pristine bytes (E00F0034, little-endian word).
    static let cbzW0Word: UInt32 = 0x3400_0FE0
    /// `b SKIP` — what the silent variant writes there (7F000014).
    static let branchWord: UInt32 = 0x1400_007F
    static let branchHex = "7F000014"
    /// Distance from the silent patch point to the newmsgid store (keeptip point).
    static let delta: UInt64 = 0x794
    /// `str <Xt>,[x19,#0x168]` with the Rt field masked off, so both the pristine
    /// `str x0` and an already-applied `str xzr` match.
    static let strNewmsgidMasked: UInt32 = 0xF900B660
    static let strRtMask: UInt32 = 0xFFFF_FFE0
    /// `str x0,[x19,#0x168]` → `str xzr,[x19,#0x168]`
    static let strX0Hex = "60B600F9"
    static let strXzrHex = "7FB600F9"

    struct Result {
        /// VA of `cbz w0` (silent patch point). keeptip point is `silentVA + delta`.
        let silentVA: UInt64
        var keeptipVA: UInt64 { silentVA + RevokeLocator.delta }
    }

    /// Scans `binary` for the revoke signature and returns the patch-point VAs.
    static func locate(binary: URL) throws -> Result {
        let data = try Data(contentsOf: binary, options: .mappedIfSafe)
        let slice = try arm64Slice(data)
        let segments = try parseSegments(slice)

        var hits: [Int] = []
        slice.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let count = raw.count
            var offset = 0
            while offset + 4 <= count {
                let word = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
                // Anchor 1 accepts both the pristine `cbz w0` and an already-applied
                // silent patch (`b`), so a machine that ran --variant silent can still
                // be located and switched to keeptip.
                if word == cbzW0Word || word == branchWord {
                    let strOffset = offset + Int(delta)
                    if strOffset + 4 <= count {
                        let str = raw.loadUnaligned(fromByteOffset: strOffset, as: UInt32.self).littleEndian
                        if str & strRtMask == strNewmsgidMasked {
                            hits.append(offset)
                        }
                    }
                }
                offset += 4
            }
        }

        guard !hits.isEmpty else { throw Error.noHit }
        let vas = hits.compactMap { fileOffsetToVA(segments, UInt64($0)) }
        guard hits.count == 1, let va = vas.first else {
            throw Error.ambiguous(count: hits.count, vas: vas)
        }
        return Result(silentVA: va)
    }

    /// Builds the `revoke-keeptip` entries for a located build: restore the `cbz`
    /// (so the parser runs and the tip renders) and zero out `newmsgid`.
    static func keeptipEntries(from result: Result) throws -> [Config.Entry] {
        [
            try Config.Entry(arch: .arm64,
                             addr: result.silentVA,
                             asmHex: "E00F0034",
                             expectedHex: ["E00F0034", branchHex]),
            try Config.Entry(arch: .arm64,
                             addr: result.keeptipVA,
                             asmHex: strXzrHex,
                             expectedHex: [strX0Hex]),
        ]
    }

    // MARK: - Mach-O helpers

    private static func arm64Slice(_ data: Data) throws -> Data {
        guard data.count >= 8 else { throw Error.notMachO }
        let magicBE = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        if magicBE == FAT_MAGIC || magicBE == FAT_CIGAM {
            let swapped = (magicBE == FAT_CIGAM)
            let nfat = data.withUnsafeBytes { raw -> UInt32 in
                let raw32 = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                return swapped ? UInt32(littleEndian: raw32) : UInt32(bigEndian: raw32)
            }
            for i in 0..<Int(nfat) {
                let base = 8 + i * 20
                guard base + 20 <= data.count else { break }
                let (cpu, off, size) = data.withUnsafeBytes { raw -> (UInt32, UInt32, UInt32) in
                    func read(_ at: Int) -> UInt32 {
                        let v = raw.loadUnaligned(fromByteOffset: base + at, as: UInt32.self)
                        return swapped ? UInt32(littleEndian: v) : UInt32(bigEndian: v)
                    }
                    return (read(0), read(8), read(12))
                }
                if cpu == UInt32(CPU_TYPE_ARM64) {
                    let start = Int(off), end = Int(off) + Int(size)
                    guard end <= data.count else { throw Error.notMachO }
                    return data.subdata(in: start..<end)
                }
            }
            throw Error.noArm64Slice
        }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard magic == MH_MAGIC_64 else { throw Error.notMachO }
        return data
    }

    private struct Segment {
        let vmaddr: UInt64
        let vmsize: UInt64
        let fileoff: UInt64
        let filesize: UInt64
    }

    private static func parseSegments(_ slice: Data) throws -> [Segment] {
        guard slice.count >= 32 else { throw Error.notMachO }
        let (magic, ncmds) = slice.withUnsafeBytes { raw -> (UInt32, UInt32) in
            (raw.loadUnaligned(as: UInt32.self).littleEndian,
             raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self).littleEndian)
        }
        guard magic == MH_MAGIC_64 else { throw Error.notMachO }

        var segments: [Segment] = []
        var offset = 32
        for _ in 0..<ncmds {
            guard offset + 8 <= slice.count else { break }
            let (cmd, cmdsize) = slice.withUnsafeBytes { raw -> (UInt32, UInt32) in
                (raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian,
                 raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self).littleEndian)
            }
            if cmd == LC_SEGMENT_64, offset + 56 <= slice.count {
                let seg = slice.withUnsafeBytes { raw -> Segment in
                    func read(_ at: Int) -> UInt64 {
                        raw.loadUnaligned(fromByteOffset: offset + at, as: UInt64.self).littleEndian
                    }
                    return Segment(vmaddr: read(24), vmsize: read(32), fileoff: read(40), filesize: read(48))
                }
                segments.append(seg)
            }
            guard cmdsize > 0 else { break }
            offset += Int(cmdsize)
        }
        return segments
    }

    private static func fileOffsetToVA(_ segments: [Segment], _ fileOffset: UInt64) -> UInt64? {
        for seg in segments where seg.fileoff <= fileOffset && fileOffset < seg.fileoff + seg.filesize {
            return seg.vmaddr + (fileOffset - seg.fileoff)
        }
        return nil
    }
}

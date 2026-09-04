//
//  RevokeLocator.swift
//  WeChatTweak
//
//  Locates the anti-revoke patch points inside `wechat.dylib` by scanning for a
//  build-invariant code signature, so a build that is not yet curated in
//  config.json can still be patched with `--auto-locate`.
//
//  The signatures are the same ones `tools/locate_revoke.py` uses: the entry `E` of
//  `parseRevokeXML` satisfies
//      E+0x270         == `cbz w0, SKIP`                  ← silent patch point
//      E+0x270+delta   == `str <Xt>,[x19,#newmsgid]`      ← keeptip patch point
//  WeChat recompiles this function every few releases, which changes the cbz
//  displacement / the newmsgid field offset / delta — one "generation" each.
//  All known generations are tabulated in `signatures.json` (repo root, the SSOT;
//  derived from the full fzlzjerry/wechat-antirecall patches.json) and generated
//  into `Signatures.generated.swift` by tools/gen_signatures.py. Both anchors must hold and the hit
//  must be unique across every generation.
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
                return "auto-locate: signature not found — this build recompiled parseRevokeXML into a new generation none of the known signatures match. Locate the patch point manually (see README) instead of --auto-locate."
            case let .ambiguous(count, vas):
                let list = vas.map { String(format: "0x%llx", $0) }.joined(separator: ", ")
                return "auto-locate: signature matched \(count) sites (\(list)) — ambiguous, refusing to guess. Locate manually (see README)."
            }
        }
    }

    /// One signature generation (see file header). The table itself lives in
    /// `signatures.json` (repo root) and is generated into `Signatures.generated.swift`.
    struct Signature: Equatable {
        let name: String
        /// Human-readable build range this generation was observed on.
        let builds: String
        /// Pristine `cbz w0, SKIP` bytes at the silent patch point (config.json spelling, big-endian hex).
        let cbzHex: String
        /// `b SKIP` the silent variant writes there.
        let branchHex: String
        /// Distance from the silent patch point to the newmsgid store (keeptip point).
        let delta: UInt64
        /// `str x0,[x19,#field]` → `str xzr,[x19,#field]`
        let strX0Hex: String
        let strXzrHex: String
        /// newmsgid field offset inside the parser's result struct (informational).
        let field: UInt64

        var cbzWord: UInt32 { Signature.word(cbzHex) }
        var branchWord: UInt32 { Signature.word(branchHex) }
        /// `str` with the Rt field masked off, so both pristine `str x0` and an applied `str xzr` match.
        var strMasked: UInt32 { Signature.word(strX0Hex) & RevokeLocator.strRtMask }

        static func word(_ hex: String) -> UInt32 {
            var bytes: [UInt8] = []
            var idx = hex.startIndex
            while idx < hex.endIndex {
                let next = hex.index(idx, offsetBy: 2)
                bytes.append(UInt8(hex[idx..<next], radix: 16)!)
                idx = next
            }
            return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        }
    }

    static let strRtMask: UInt32 = 0xFFFF_FFE0

    struct Result {
        /// VA of `cbz w0` (silent patch point). keeptip point is `silentVA + signature.delta`.
        let silentVA: UInt64
        let signature: Signature
        var keeptipVA: UInt64 { silentVA + signature.delta }
    }

    /// Scans `binary` for the revoke signature and returns the patch-point VAs.
    static func locate(binary: URL) throws -> Result {
        let data = try Data(contentsOf: binary, options: .mappedIfSafe)
        let slice = try arm64Slice(data)
        let segments = try parseSegments(slice)

        // Precompute anchor words once; the scan is a single pass over ~170MB.
        let anchors: [(cbz: UInt32, branch: UInt32, delta: Int, strMasked: UInt32, sig: Signature)] =
            signatures.map { ($0.cbzWord, $0.branchWord, Int($0.delta), $0.strMasked, $0) }

        var hits: [(offset: Int, sig: Signature)] = []
        slice.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let count = raw.count
            var offset = 0
            while offset + 4 <= count {
                let word = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
                for a in anchors {
                    // Anchor 1 accepts both the pristine `cbz w0` and an already-applied
                    // silent patch (`b`), so a machine that ran --variant silent can still
                    // be located and switched to keeptip.
                    guard word == a.cbz || word == a.branch else { continue }
                    let strOffset = offset + a.delta
                    if strOffset + 4 <= count {
                        let str = raw.loadUnaligned(fromByteOffset: strOffset, as: UInt32.self).littleEndian
                        if str & strRtMask == a.strMasked {
                            hits.append((offset, a.sig))
                        }
                    }
                }
                offset += 4
            }
        }

        guard !hits.isEmpty else { throw Error.noHit }
        let vas = hits.compactMap { fileOffsetToVA(segments, UInt64($0.offset)) }
        guard hits.count == 1, let va = vas.first else {
            throw Error.ambiguous(count: hits.count, vas: vas)
        }
        return Result(silentVA: va, signature: hits[0].sig)
    }

    /// Builds the `revoke-keeptip` entries for a located build: restore the `cbz`
    /// (so the parser runs and the tip renders) and zero out `newmsgid`.
    static func keeptipEntries(from result: Result) throws -> [Config.Entry] {
        [
            try Config.Entry(arch: .arm64,
                             addr: result.silentVA,
                             asmHex: result.signature.cbzHex,
                             expectedHex: [result.signature.cbzHex, result.signature.branchHex]),
            try Config.Entry(arch: .arm64,
                             addr: result.keeptipVA,
                             asmHex: result.signature.strXzrHex,
                             expectedHex: [result.signature.strX0Hex]),
        ]
    }

    // MARK: - Mach-O helpers

    static func arm64Slice(_ data: Data) throws -> Data {
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

    struct Segment {
        let vmaddr: UInt64
        let vmsize: UInt64
        let fileoff: UInt64
        let filesize: UInt64
    }

    static func parseSegments(_ slice: Data) throws -> [Segment] {
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

    static func fileOffsetToVA(_ segments: [Segment], _ fileOffset: UInt64) -> UInt64? {
        for seg in segments where seg.fileoff <= fileOffset && fileOffset < seg.fileoff + seg.filesize {
            return seg.vmaddr + (fileOffset - seg.fileoff)
        }
        return nil
    }
}

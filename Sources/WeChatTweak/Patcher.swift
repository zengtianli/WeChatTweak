//
//  Patcher.swift
//  WeChatTweak
//
//  Created by Sunny Young on 2025/12/4.
//

import Darwin
import MachO
import Foundation

struct Patcher {
    enum Error: LocalizedError {
        case invalidFile
        case not64BitMachO(magic: UInt32)
        case vaNotFound(arch: String, va: UInt64)
        case noArchMatched
        case expectedMismatch(arch: String, va: UInt64, found: String, want: [String])

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                return "Invalid binary file"
            case let .not64BitMachO(magic):
                return "Not a 64-bit Mach-O (magic: \(String(format: "0x%08x", magic)))"
            case let .vaNotFound(arch, va):
                return "[\(arch)] VA \(String(format: "0x%llx", va)) not found in any segment"
            case .noArchMatched:
                return "No matching arch/entries to patch"
            case let .expectedMismatch(arch, va, found, want):
                return "[\(arch)] byte mismatch at \(String(format: "0x%llx", va)): found \(found), expected one of \(want.joined(separator: " / ")). Wrong WeChat build — refusing to patch."
            }
        }
    }

    /// What the bytes at an entry's address currently are, relative to that entry.
    enum State: String {
        /// Bytes equal `asm` — the patch is applied.
        case patched
        /// Bytes match one of `expected` (or `expected` is empty) — patchable original.
        case pristine
        /// Neither — wrong build, foreign patch, or a half-applied write.
        case unknown
    }

    struct Inspection {
        let entry: Config.Entry
        let current: Data
        var state: State {
            if current == entry.asm { return .patched }
            if entry.expected.isEmpty || entry.expected.contains(current) { return .pristine }
            return .unknown
        }
        var currentHex: String { current.map { String(format: "%02X", $0) }.joined() }
    }

    static func patch(binary: URL, entries: [Config.Entry]) throws {
        guard !entries.isEmpty else { throw Error.noArchMatched }
        let fh = try open(binary, writable: true)
        defer { try? fh.close() }

        var patchedCount = 0
        for (cputype, sliceOffset) in try slices(fh) {
            for entry in entries where entry.arch.cpu == cputype {
                try patchOne(file: fh, sliceOffset: sliceOffset, entry: entry)
                patchedCount += 1
            }
        }
        if patchedCount <= 0 {
            throw Error.noArchMatched
        }
    }

    /// Read-only twin of `patch`: reports the current bytes/state at every entry without writing.
    static func inspect(binary: URL, entries: [Config.Entry]) throws -> [Inspection] {
        guard !entries.isEmpty else { throw Error.noArchMatched }
        let fh = try open(binary, writable: false)
        defer { try? fh.close() }

        var out: [Inspection] = []
        for (cputype, sliceOffset) in try slices(fh) {
            for entry in entries where entry.arch.cpu == cputype {
                let fileOffset = try fileOffset(in: fh, sliceOffset: sliceOffset, va: entry.addr, arch: entry.arch.rawValue)
                try fh.seek(toOffset: fileOffset)
                out.append(Inspection(entry: entry, current: try fh.read(upToCount: entry.asm.count) ?? Data()))
            }
        }
        if out.isEmpty {
            throw Error.noArchMatched
        }
        return out
    }

    // MARK: - Internals

    private static func open(_ binary: URL, writable: Bool) throws -> FileHandle {
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw Error.invalidFile
        }
        return writable ? try FileHandle(forUpdating: binary) : try FileHandle(forReadingFrom: binary)
    }

    /// (cputype, slice file offset) for every slice: fat → each fat_arch; thin → the file itself.
    private static func slices(_ fh: FileHandle) throws -> [(UInt32, UInt64)] {
        try fh.seek(toOffset: 0)
        guard let magicData = try fh.read(upToCount: 4), magicData.count == 4 else {
            throw Error.invalidFile
        }
        let magicBE = magicData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let isSwappedFat = (magicBE == FAT_CIGAM)

        if magicBE == FAT_MAGIC || magicBE == FAT_CIGAM {
            // FAT header: magic(4) + nfat_arch(4), then fat_arch: cputype cpusub offset size align (big-endian)
            guard let nfatData = try fh.read(upToCount: 4), nfatData.count == 4 else {
                throw Error.invalidFile
            }
            let rawNfat = nfatData.withUnsafeBytes { $0.load(as: UInt32.self) }
            let nfat = isSwappedFat ? UInt32(littleEndian: rawNfat) : UInt32(bigEndian: rawNfat)
            var out: [(UInt32, UInt64)] = []
            for _ in 0..<nfat {
                guard let archData = try fh.read(upToCount: 20), archData.count == 20 else {
                    throw Error.invalidFile
                }
                let rawCpu = archData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
                let rawOff = archData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                let cputype = isSwappedFat ? UInt32(littleEndian: rawCpu) : UInt32(bigEndian: rawCpu)
                let offset = isSwappedFat ? UInt32(littleEndian: rawOff) : UInt32(bigEndian: rawOff)
                out.append((cputype, UInt64(offset)))
            }
            return out
        }

        // thin Mach-O: mach_header_64 (little-endian)
        try fh.seek(toOffset: 0)
        guard let hdr = try fh.read(upToCount: 32), hdr.count == 32 else {
            throw Error.invalidFile
        }
        let magic = hdr.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let cputype = hdr.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
        guard magic == MH_MAGIC_64 else {
            throw Error.not64BitMachO(magic: magic)
        }
        return [(cputype, 0)]
    }

    /// Absolute file offset of `va` inside the slice at `sliceOffset` (walks LC_SEGMENT_64).
    private static func fileOffset(in fh: FileHandle, sliceOffset: UInt64, va: UInt64, arch: String) throws -> UInt64 {
        try fh.seek(toOffset: sliceOffset)
        guard let hdr = try fh.read(upToCount: 32), hdr.count == 32 else {
            throw Error.invalidFile
        }
        let magic = hdr.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let ncmds = hdr.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self).littleEndian }
        guard magic == MH_MAGIC_64 else {
            throw Error.not64BitMachO(magic: magic)
        }

        var lcOffset = sliceOffset + 32
        for _ in 0..<ncmds {
            try fh.seek(toOffset: lcOffset)
            guard let lcHead = try fh.read(upToCount: 8), lcHead.count == 8 else {
                throw Error.invalidFile
            }
            let cmd = lcHead.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let cmdsize = lcHead.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
            if cmd == LC_SEGMENT_64 {
                guard let segData = try fh.read(upToCount: 64), segData.count == 64 else {
                    throw Error.invalidFile
                }
                let vmaddr = segData.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self).littleEndian }
                let vmsize = segData.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self).littleEndian }
                let fileoff = segData.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt64.self).littleEndian }
                if vmaddr <= va && va < vmaddr + vmsize {
                    return sliceOffset + fileoff + (va - vmaddr)
                }
            }
            lcOffset += UInt64(cmdsize)
        }
        throw Error.vaNotFound(arch: arch, va: va)
    }

    private static func patchOne(file fh: FileHandle, sliceOffset: UInt64, entry: Config.Entry) throws {
        let archName = entry.arch.rawValue
        let fileOffset = try fileOffset(in: fh, sliceOffset: sliceOffset, va: entry.addr, arch: archName)

        // Read current bytes to guard against patching the wrong build.
        try fh.seek(toOffset: fileOffset)
        let current = try fh.read(upToCount: entry.asm.count) ?? Data()

        if current == entry.asm {
            print("[\(archName)] VA \(String(format: "0x%llx", entry.addr)) already patched — skipping")
            return
        }
        if !entry.expected.isEmpty && !entry.expected.contains(current) {
            throw Error.expectedMismatch(
                arch: archName,
                va: entry.addr,
                found: current.map { String(format: "%02X", $0) }.joined(),
                want: entry.expected.map { $0.map { String(format: "%02X", $0) }.joined() }
            )
        }

        print("[\(archName)] patch VA=\(String(format: "0x%llx", entry.addr)), fileoff=\(String(format: "0x%llx", fileOffset)): \(current.map { String(format: "%02X", $0) }.joined()) -> \(entry.asm.map { String(format: "%02X", $0) }.joined())")

        try fh.seek(toOffset: fileOffset)
        try fh.write(contentsOf: entry.asm)
    }
}

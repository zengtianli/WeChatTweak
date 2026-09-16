//
//  Patcher.swift
//  WeChatTweak
//
//  Created by Sunny Young on 2025/12/4.
//

import Darwin
import Foundation
import MachO

struct Patcher {
    enum Error: LocalizedError {
        case invalidFile
        case not64BitMachO(magic: UInt32)
        case vaNotFound(arch: String, va: UInt64)
        case emptyPatch(arch: String, va: UInt64)
        case invalidExpectedLength(arch: String, va: UInt64)
        case expectedMismatch(arch: String, va: UInt64, found: String, want: [String])
        case overlappingPatches
        case noArchMatched

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                return "Invalid or malformed binary file"
            case let .not64BitMachO(magic):
                return "Not a 64-bit Mach-O (magic: \(String(format: "0x%08x", magic)))"
            case let .vaNotFound(arch, va):
                return "[\(arch)] VA \(String(format: "0x%llx", va)) is not in a file-backed __TEXT segment"
            case let .emptyPatch(arch, va):
                return "[\(arch)] empty patch at \(String(format: "0x%llx", va))"
            case let .invalidExpectedLength(arch, va):
                return "[\(arch)] expected bytes have a different length from the patch at \(String(format: "0x%llx", va))"
            case let .expectedMismatch(arch, va, found, want):
                return "[\(arch)] byte mismatch at \(String(format: "0x%llx", va)): found \(found), expected one of \(want.joined(separator: " / ")). Wrong WeChat build — refusing to patch."
            case .overlappingPatches:
                return "Patch ranges overlap — refusing to apply an ambiguous config"
            case .noArchMatched:
                return "No matching arch/entries to patch"
            }
        }
    }

    enum State: String {
        case patched
        case pristine
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

        var currentHex: String { current.hexString }
    }

    private struct Slice {
        let cpu: UInt32
        let offset: UInt64
        let size: UInt64
    }

    private struct PatchPlan {
        let archName: String
        let targetVA: UInt64
        let fileOffset: UInt64
        let patch: Data
        let original: Data

        var isAlreadyPatched: Bool { original == patch }
    }

    /// Every address, range and expected byte sequence is checked before the first
    /// write. A failed write restores all ranges from the read-time plan. A versioned
    /// backup is made only before a real write, never for an idempotent re-run.
    static func patch(binary: URL, entries: [Config.Entry], backupVersion: String? = nil) throws {
        guard !entries.isEmpty else { throw Error.noArchMatched }
        for entry in entries {
            guard !entry.asm.isEmpty else {
                throw Error.emptyPatch(arch: entry.arch.rawValue, va: entry.addr)
            }
            guard entry.expected.allSatisfy({ $0.count == entry.asm.count }) else {
                throw Error.invalidExpectedLength(arch: entry.arch.rawValue, va: entry.addr)
            }
        }

        let fh = try open(binary, writable: true)
        defer { try? fh.close() }
        guard flock(fh.fileDescriptor, LOCK_EX) == 0 else { throw Error.invalidFile }
        defer { flock(fh.fileDescriptor, LOCK_UN) }

        let fileSize = try fh.seekToEnd()
        let slices = try parseSlices(file: fh, fileSize: fileSize)
        var plans: [PatchPlan] = []
        for slice in slices {
            for entry in entries where entry.arch.cpu == slice.cpu {
                plans.append(try makePlan(file: fh, fileSize: fileSize, slice: slice, entry: entry, validateExpected: true))
            }
        }
        guard !plans.isEmpty else { throw Error.noArchMatched }
        try validateNoOverlaps(plans)

        if plans.contains(where: { !$0.isAlreadyPatched }), let backupVersion {
            try backup(binary: binary, version: backupVersion)
        }
        // Backup is an external file operation; re-read under the advisory lock just
        // before writing so that a cooperative writer cannot race the plan.
        try ensureUnchanged(plans, file: fh, fileSize: fileSize)

        do {
            for plan in plans where !plan.isAlreadyPatched {
                try fh.seek(toOffset: plan.fileOffset)
                try fh.write(contentsOf: plan.patch)
                print("[\(plan.archName)] patch VA=\(String(format: "0x%llx", plan.targetVA)), fileoff=\(String(format: "0x%llx", plan.fileOffset)): \(plan.original.hexString) -> \(plan.patch.hexString)")
            }
            try fh.synchronize()
            for plan in plans {
                let written = try readExactly(file: fh, offset: plan.fileOffset, count: plan.patch.count, fileSize: fileSize)
                guard written == plan.patch else { throw Error.invalidFile }
            }
        } catch {
            for plan in plans where !plan.isAlreadyPatched {
                try? fh.seek(toOffset: plan.fileOffset)
                try? fh.write(contentsOf: plan.original)
            }
            try? fh.synchronize()
            throw error
        }

        for plan in plans where plan.isAlreadyPatched {
            print("[\(plan.archName)] VA \(String(format: "0x%llx", plan.targetVA)) already patched — skipping")
        }
    }

    static func inspect(binary: URL, entries: [Config.Entry]) throws -> [Inspection] {
        guard !entries.isEmpty else { throw Error.noArchMatched }
        let fh = try open(binary, writable: false)
        defer { try? fh.close() }

        let fileSize = try fh.seekToEnd()
        let slices = try parseSlices(file: fh, fileSize: fileSize)
        var result: [Inspection] = []
        for slice in slices {
            for entry in entries where entry.arch.cpu == slice.cpu {
                let plan = try makePlan(file: fh, fileSize: fileSize, slice: slice, entry: entry, validateExpected: false)
                result.append(Inspection(entry: entry, current: plan.original))
            }
        }
        guard !result.isEmpty else { throw Error.noArchMatched }
        return result
    }

    // MARK: - Planning

    private static func open(_ binary: URL, writable: Bool) throws -> FileHandle {
        guard FileManager.default.fileExists(atPath: binary.path) else { throw Error.invalidFile }
        return writable ? try FileHandle(forUpdating: binary) : try FileHandle(forReadingFrom: binary)
    }

    private static func parseSlices(file fh: FileHandle, fileSize: UInt64) throws -> [Slice] {
        let magicData = try readExactly(file: fh, offset: 0, count: 4, fileSize: fileSize)
        let magicBE = readUInt32BE(magicData, at: 0)
        if magicBE == FAT_MAGIC || magicBE == FAT_CIGAM {
            let header = try readExactly(file: fh, offset: 0, count: 8, fileSize: fileSize)
            let swapped = magicBE == FAT_CIGAM
            let nfat = swapped ? readUInt32LE(header, at: 4) : readUInt32BE(header, at: 4)
            let (tableSize, tableOverflow) = UInt64(nfat).multipliedReportingOverflow(by: 20)
            let (tableEnd, endOverflow) = UInt64(8).addingReportingOverflow(tableSize)
            guard !tableOverflow, !endOverflow, tableEnd <= fileSize else { throw Error.invalidFile }

            var slices: [Slice] = []
            slices.reserveCapacity(Int(nfat))
            for index in 0..<UInt64(nfat) {
                let entryOffset = 8 + index * 20
                let data = try readExactly(file: fh, offset: entryOffset, count: 20, fileSize: fileSize)
                let cpu = swapped ? readUInt32LE(data, at: 0) : readUInt32BE(data, at: 0)
                let offset = UInt64(swapped ? readUInt32LE(data, at: 8) : readUInt32BE(data, at: 8))
                let size = UInt64(swapped ? readUInt32LE(data, at: 12) : readUInt32BE(data, at: 12))
                guard offset >= tableEnd,
                      size >= 32,
                      let sliceEnd = adding(offset, size),
                      sliceEnd <= fileSize else { throw Error.invalidFile }
                slices.append(Slice(cpu: cpu, offset: offset, size: size))
            }
            let sorted = slices.sorted { $0.offset < $1.offset }
            for (previous, current) in zip(sorted, sorted.dropFirst()) {
                guard let previousEnd = adding(previous.offset, previous.size), previousEnd <= current.offset else {
                    throw Error.invalidFile
                }
            }
            return slices
        }

        let header = try readExactly(file: fh, offset: 0, count: 32, fileSize: fileSize)
        let magic = readUInt32LE(header, at: 0)
        guard magic == MH_MAGIC_64 else { throw Error.not64BitMachO(magic: magic) }
        return [Slice(cpu: readUInt32LE(header, at: 4), offset: 0, size: fileSize)]
    }

    private static func makePlan(file fh: FileHandle,
                                 fileSize: UInt64,
                                 slice: Slice,
                                 entry: Config.Entry,
                                 validateExpected: Bool) throws -> PatchPlan {
        let header = try readExactly(file: fh, offset: slice.offset, count: 32, fileSize: fileSize)
        let magic = readUInt32LE(header, at: 0)
        guard magic == MH_MAGIC_64 else { throw Error.not64BitMachO(magic: magic) }
        guard readUInt32LE(header, at: 4) == slice.cpu else { throw Error.invalidFile }

        let ncmds = readUInt32LE(header, at: 16)
        let sizeofcmds = UInt64(readUInt32LE(header, at: 20))
        guard let sliceEnd = adding(slice.offset, slice.size),
              let commandsStart = adding(slice.offset, 32),
              let commandsEnd = adding(commandsStart, sizeofcmds),
              commandsEnd <= sliceEnd,
              commandsEnd <= fileSize else { throw Error.invalidFile }

        var commandOffset = commandsStart
        var found: PatchPlan?
        for _ in 0..<ncmds {
            guard let headerEnd = adding(commandOffset, 8), headerEnd <= commandsEnd else { throw Error.invalidFile }
            let commandHeader = try readExactly(file: fh, offset: commandOffset, count: 8, fileSize: fileSize)
            let command = readUInt32LE(commandHeader, at: 0)
            let commandSize = UInt64(readUInt32LE(commandHeader, at: 4))
            guard commandSize >= 8,
                  let nextCommand = adding(commandOffset, commandSize),
                  nextCommand <= commandsEnd else { throw Error.invalidFile }

            if command == LC_SEGMENT_64 {
                guard commandSize >= 72 else { throw Error.invalidFile }
                let segment = try readExactly(file: fh, offset: commandOffset + 8, count: 64, fileSize: fileSize)
                let name = String(bytes: segment.prefix { $0 != 0 }, encoding: .utf8) ?? ""
                let vmaddr = readUInt64LE(segment, at: 16)
                let vmsize = readUInt64LE(segment, at: 24)
                let fileoff = readUInt64LE(segment, at: 32)
                let filesize = readUInt64LE(segment, at: 40)
                guard let segmentEnd = adding(fileoff, filesize), segmentEnd <= slice.size else { throw Error.invalidFile }

                if entry.addr >= vmaddr {
                    let offsetInSegment = entry.addr - vmaddr
                    if offsetInSegment < vmsize {
                        guard found == nil,
                              name == "__TEXT",
                              let patchLength = UInt64(exactly: entry.asm.count),
                              let patchEnd = adding(offsetInSegment, patchLength),
                              patchEnd <= vmsize,
                              patchEnd <= filesize,
                              let relativeFileOffset = adding(fileoff, offsetInSegment),
                              let fileOffset = adding(slice.offset, relativeFileOffset),
                              let fileEnd = adding(fileOffset, patchLength),
                              fileEnd <= sliceEnd,
                              fileEnd <= fileSize else {
                            throw Error.vaNotFound(arch: entry.arch.rawValue, va: entry.addr)
                        }
                        let original = try readExactly(file: fh, offset: fileOffset, count: entry.asm.count, fileSize: fileSize)
                        if validateExpected,
                           original != entry.asm,
                           !entry.expected.isEmpty,
                           !entry.expected.contains(original) {
                            throw Error.expectedMismatch(arch: entry.arch.rawValue,
                                                         va: entry.addr,
                                                         found: original.hexString,
                                                         want: entry.expected.map(\.hexString))
                        }
                        found = PatchPlan(archName: entry.arch.rawValue,
                                          targetVA: entry.addr,
                                          fileOffset: fileOffset,
                                          patch: entry.asm,
                                          original: original)
                    }
                }
            }
            commandOffset = nextCommand
        }
        guard commandOffset == commandsEnd else { throw Error.invalidFile }
        guard let found else { throw Error.vaNotFound(arch: entry.arch.rawValue, va: entry.addr) }
        return found
    }

    private static func validateNoOverlaps(_ plans: [PatchPlan]) throws {
        let sorted = plans.sorted { $0.fileOffset < $1.fileOffset }
        for (previous, current) in zip(sorted, sorted.dropFirst()) {
            guard let previousEnd = adding(previous.fileOffset, UInt64(previous.patch.count)),
                  previousEnd <= current.fileOffset else { throw Error.overlappingPatches }
        }
    }

    private static func ensureUnchanged(_ plans: [PatchPlan], file fh: FileHandle, fileSize: UInt64) throws {
        for plan in plans {
            let current = try readExactly(file: fh, offset: plan.fileOffset, count: plan.original.count, fileSize: fileSize)
            guard current == plan.original else {
                throw Error.expectedMismatch(arch: plan.archName,
                                             va: plan.targetVA,
                                             found: current.hexString,
                                             want: [plan.original.hexString])
            }
        }
    }

    private static func backup(binary: URL, version: String) throws {
        guard !version.isEmpty, !version.contains("/"), !version.utf8.contains(0) else { throw Error.invalidFile }
        let backupURL = URL(fileURLWithPath: binary.path + "." + version + ".bak")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        try FileManager.default.copyItem(at: binary, to: backupURL)
        print("Backup created: \(backupURL.path)")
    }

    // MARK: - Checked binary I/O

    private static func readExactly(file fh: FileHandle, offset: UInt64, count: Int, fileSize: UInt64) throws -> Data {
        guard count >= 0,
              let length = UInt64(exactly: count),
              let end = adding(offset, length),
              end <= fileSize else { throw Error.invalidFile }
        try fh.seek(toOffset: offset)
        guard let data = try fh.read(upToCount: count), data.count == count else { throw Error.invalidFile }
        return data
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].enumerated().reduce(0) { $0 | (UInt32($1.element) << UInt32($1.offset * 8)) }
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].enumerated().reduce(0) { $0 | (UInt64($1.element) << UInt64($1.offset * 8)) }
    }
}

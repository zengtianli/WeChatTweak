//
//  UpdateLocator.swift
//  WeChatTweak
//
//  Locates the "block auto-update" patch points (config.json target `update`) inside
//  `wechat.dylib` by walking the Objective-C metadata instead of scanning for bytes:
//      __objc_classlist → class_t(XAppUpdateManager) → class_ro_t → method list → IMP by selector
//  Four trigger methods get `ret` at their entry; the two force-update switches get their
//  getter pinned to `mov w0,#0; ret` and their setter to `ret`. Every IMP found by name is
//  additionally checked for the instruction shape we expect (prologue / `ldrb w0,[x0,#f]; ret` /
//  `strb w2,[x0,#f]`) — same name but different code means WeChat changed the implementation,
//  and we refuse rather than write `ret` into something we don't understand.
//
//  Class and method names are the SSOT `signatures.json` ("update"), generated into
//  `Signatures.generated.swift`; tools/locate_update.py is the Python twin used to curate
//  config.json. Method: fzlzjerry/wechat-antirecall MAINTAINING.md §屏蔽更新.
//

import Foundation
import MachO

struct UpdateLocator {
    enum Error: LocalizedError {
        case noClassList
        case classNotFound(String)
        case ambiguousClass(String, Int)
        case methodsMissing([String])
        case unexpectedCode(method: String, va: UInt64, found: String, want: String)
        case accessorFieldMismatch(getter: String, setter: String, gField: UInt64, sField: UInt64)
        case badPointer(UInt64, readAt: UInt64)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .noClassList:
                return "auto-locate(update): binary has no __objc_classlist section"
            case let .classNotFound(name):
                return "auto-locate(update): Objective-C class \(name) not found — WeChat renamed or moved its updater. Port the rule in signatures.json (\"update\") or run with --no-block-update."
            case let .ambiguousClass(name, count):
                return "auto-locate(update): \(count) classes named \(name) — refusing to guess"
            case let .methodsMissing(names):
                return "auto-locate(update): \(UpdateLocator.className) lacks method(s): \(names.joined(separator: ", "))"
            case let .unexpectedCode(method, va, found, want):
                return String(format: "auto-locate(update): %@ at 0x%llx starts with %@, expected %@ — WeChat changed this function; refusing to patch code we don't recognise", method, va, found, want)
            case let .accessorFieldMismatch(getter, setter, gField, sField):
                return String(format: "auto-locate(update): %@ reads field 0x%llx but %@ writes field 0x%llx — not the accessor pair we expect", getter, gField, setter, sField)
            case let .badPointer(value, at):
                return String(format: "auto-locate(update): pointer 0x%llx (read at 0x%llx) falls outside every segment", value, at)
            case let .malformed(what):
                return "auto-locate(update): malformed Mach-O: \(what)"
            }
        }
    }

    struct Hit {
        let method: String
        let va: UInt64
        /// The bytes at `va` are already the patched form (idempotent re-run / doctor).
        let alreadyPatched: Bool
        let entry: Config.Entry
    }

    static let retWord: UInt32 = 0xD65F_03C0        // ret
    static let movW0ZeroWord: UInt32 = 0x5280_0000  // mov w0, #0
    private static let ldrbW0X0Mask: UInt32 = 0xFFC0_03FF, ldrbW0X0: UInt32 = 0x3940_0000  // ldrb w0,[x0,#imm12]
    private static let strbW2X0Mask: UInt32 = 0xFFC0_03FF, strbW2X0: UInt32 = 0x3900_0002  // strb w2,[x0,#imm12]

    /// Function entry: `stp` (pre-index or signed offset) / `sub sp,sp,#imm` / `pacibsp`.
    static func isPrologue(_ w: UInt32) -> Bool {
        let hi = w & 0xFFC0_0000
        return hi == 0xA980_0000 || hi == 0xA900_0000 || (w & 0xFF00_03FF) == 0xD100_03FF || w == 0xD503_237F
    }

    /// Returns the eight patch points in config order: ret methods, then getter/setter per accessor pair.
    static func locate(binary: URL) throws -> [Hit] {
        let data = try Data(contentsOf: binary, options: .mappedIfSafe)
        let image = try Image(slice: try RevokeLocator.arm64Slice(data))
        let cls = try image.findClass(named: className)
        let methods = try image.methods(ofClass: cls)

        let wanted = retMethods + zeroAccessors.flatMap { [$0.getter, $0.setter] }
        let missing = wanted.filter { methods[$0] == nil }
        guard missing.isEmpty else { throw Error.methodsMissing(missing) }

        var hits: [Hit] = []
        for name in retMethods {
            let va = methods[name]!
            let w = try image.word(at: va)
            if w == retWord {
                hits.append(Hit(method: name, va: va, alreadyPatched: true,
                                entry: try Config.Entry(arch: .arm64, addr: va, asmHex: retHex, expectedHex: [retHex])))
            } else if isPrologue(w) {
                hits.append(Hit(method: name, va: va, alreadyPatched: false,
                                entry: try Config.Entry(arch: .arm64, addr: va, asmHex: retHex, expectedHex: [try image.hex(at: va, count: 4)])))
            } else {
                throw Error.unexpectedCode(method: name, va: va, found: try image.hex(at: va, count: 4), want: "a stp / sub-sp prologue")
            }
        }
        for pair in zeroAccessors {
            let g = methods[pair.getter]!, s = methods[pair.setter]!
            let g0 = try image.word(at: g), g1 = try image.word(at: g + 4), s0 = try image.word(at: s)
            var gField: UInt64?, sField: UInt64?
            let getterAsm = movW0ZeroHex + retHex
            if g0 == movW0ZeroWord && g1 == retWord {
                hits.append(Hit(method: pair.getter, va: g, alreadyPatched: true,
                                entry: try Config.Entry(arch: .arm64, addr: g, asmHex: getterAsm, expectedHex: [getterAsm])))
            } else if g0 & ldrbW0X0Mask == ldrbW0X0 && g1 == retWord {
                gField = UInt64((g0 >> 10) & 0xFFF)
                hits.append(Hit(method: pair.getter, va: g, alreadyPatched: false,
                                entry: try Config.Entry(arch: .arm64, addr: g, asmHex: getterAsm, expectedHex: [try image.hex(at: g, count: 8)])))
            } else {
                throw Error.unexpectedCode(method: pair.getter, va: g, found: try image.hex(at: g, count: 8), want: "ldrb w0,[x0,#field]; ret")
            }
            if s0 == retWord {
                hits.append(Hit(method: pair.setter, va: s, alreadyPatched: true,
                                entry: try Config.Entry(arch: .arm64, addr: s, asmHex: retHex, expectedHex: [retHex])))
            } else if s0 & strbW2X0Mask == strbW2X0 {
                sField = UInt64((s0 >> 10) & 0xFFF)
                hits.append(Hit(method: pair.setter, va: s, alreadyPatched: false,
                                entry: try Config.Entry(arch: .arm64, addr: s, asmHex: retHex, expectedHex: [try image.hex(at: s, count: 4)])))
            } else {
                throw Error.unexpectedCode(method: pair.setter, va: s, found: try image.hex(at: s, count: 4), want: "strb w2,[x0,#field]")
            }
            if let gf = gField, let sf = sField, gf != sf {
                throw Error.accessorFieldMismatch(getter: pair.getter, setter: pair.setter, gField: gf, sField: sf)
            }
        }
        return hits
    }

    // MARK: - Mach-O image with ObjC metadata access

    struct Image {
        struct Section {
            let segname: String
            let sectname: String
            let addr: UInt64
            let size: UInt64
            let offset: UInt32
        }

        let slice: Data
        let segments: [RevokeLocator.Segment]
        let sections: [Section]

        init(slice: Data) throws {
            self.slice = slice
            self.segments = try RevokeLocator.parseSegments(slice)
            self.sections = try Image.parseSections(slice)
        }

        static func parseSections(_ slice: Data) throws -> [Section] {
            guard slice.count >= 32 else { throw Error.malformed("header truncated") }
            let ncmds = slice.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self).littleEndian }
            var out: [Section] = []
            var offset = 32
            for _ in 0..<ncmds {
                guard offset + 8 <= slice.count else { break }
                let (cmd, cmdsize) = slice.withUnsafeBytes { raw -> (UInt32, UInt32) in
                    (raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian,
                     raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self).littleEndian)
                }
                if cmd == LC_SEGMENT_64, offset + 72 <= slice.count {
                    let nsects = slice.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 64, as: UInt32.self).littleEndian }
                    for i in 0..<Int(nsects) {
                        let q = offset + 72 + 80 * i
                        guard q + 80 <= slice.count else { throw Error.malformed("section header truncated") }
                        let sect = slice.withUnsafeBytes { raw -> Section in
                            func str(_ at: Int) -> String {
                                let bytes = (0..<16).map { raw.load(fromByteOffset: at + $0, as: UInt8.self) }
                                return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                            }
                            return Section(segname: str(q + 16), sectname: str(q),
                                           addr: raw.loadUnaligned(fromByteOffset: q + 32, as: UInt64.self).littleEndian,
                                           size: raw.loadUnaligned(fromByteOffset: q + 40, as: UInt64.self).littleEndian,
                                           offset: raw.loadUnaligned(fromByteOffset: q + 48, as: UInt32.self).littleEndian)
                        }
                        out.append(sect)
                    }
                }
                guard cmdsize > 0 else { break }
                offset += Int(cmdsize)
            }
            return out
        }

        /// File offset (within the slice) backing `count` bytes at `va`; throws if not file-backed.
        func offset(of va: UInt64, count: Int) throws -> Int {
            for seg in segments where seg.vmaddr <= va && va + UInt64(count) <= seg.vmaddr + seg.filesize {
                let off = seg.fileoff + (va - seg.vmaddr)
                guard off + UInt64(count) <= UInt64(slice.count) else { break }
                return Int(off)
            }
            throw Error.badPointer(va, readAt: va)
        }

        func word(at va: UInt64) throws -> UInt32 {
            let off = try offset(of: va, count: 4)
            return slice.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self).littleEndian }
        }

        /// Reads a pointer-sized field. dyld chained fixups encode a rebase target in the low
        /// 36 bits (upper bits: chain `next` / bind flag), so strip them when present. The decoded
        /// value must land inside a segment — anything else means our decoding assumption broke.
        func pointer(at va: UInt64) throws -> UInt64 {
            let off = try offset(of: va, count: 8)
            var v = slice.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt64.self).littleEndian }
            if v == 0 { return 0 }
            if v >> 36 != 0 { v &= 0xF_FFFF_FFFF }
            guard segments.contains(where: { $0.vmaddr <= v && v < $0.vmaddr + $0.vmsize }) else {
                throw Error.badPointer(v, readAt: va)
            }
            return v
        }

        func cString(at va: UInt64, max: Int = 512) throws -> String {
            let start = try offset(of: va, count: 1)
            let end = min(start + max, slice.count)
            var bytes: [UInt8] = []
            slice.withUnsafeBytes { raw in
                for i in start..<end {
                    let b = raw.load(fromByteOffset: i, as: UInt8.self)
                    if b == 0 { return }
                    bytes.append(b)
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        /// config.json spelling: bytes in file order, uppercase hex.
        func hex(at va: UInt64, count: Int) throws -> String {
            let off = try offset(of: va, count: count)
            return slice[off..<(off + count)].map { String(format: "%02X", $0) }.joined()
        }

        func findClass(named name: String) throws -> UInt64 {
            let lists = sections.filter { $0.sectname == "__objc_classlist" }
            guard !lists.isEmpty else { throw Error.noClassList }
            var found: [UInt64] = []
            for list in lists {
                for i in 0..<Int(list.size / 8) {
                    // Some (Swift) classes have layouts we don't model; skip entries we can't decode
                    // instead of failing the whole lookup.
                    guard let cls = try? pointer(at: list.addr + UInt64(8 * i)), cls != 0,
                          let ro = try? pointer(at: cls + 32),
                          let namePtr = try? pointer(at: (ro & ~7) + 24),
                          let n = try? cString(at: namePtr) else { continue }
                    if n == name { found.append(cls) }
                }
            }
            guard !found.isEmpty else { throw Error.classNotFound(name) }
            guard found.count == 1 else { throw Error.ambiguousClass(name, found.count) }
            return found[0]
        }

        /// Instance + class methods merged; an instance method wins over a same-named class method.
        func methods(ofClass cls: UInt64) throws -> [String: UInt64] {
            let ro = try pointer(at: cls + 32) & ~7
            let instance = try methodList(at: try pointer(at: ro + 32))
            let meta = try pointer(at: cls)  // isa → metaclass
            let metaRo = try pointer(at: meta + 32) & ~7
            let classMethods = try methodList(at: try pointer(at: metaRo + 32))
            var out: [String: UInt64] = [:]
            for (sel, imp) in classMethods + instance { out[sel] = imp }
            return out
        }

        /// Supports relative method lists (12-byte entries, the default since 2020) and absolute ones (24-byte).
        func methodList(at ml: UInt64) throws -> [(String, UInt64)] {
            if ml == 0 { return [] }
            let ef = try word(at: ml), count = try word(at: ml + 4)
            let relative = ef & 0x8000_0000 != 0
            let directSelectors = ef & 0x4000_0000 != 0
            let entsize = UInt64(ef & 0xFFFC)
            guard count < 100_000, entsize >= 12 else {
                throw Error.malformed(String(format: "method list at 0x%llx (entsize=%llu count=%u)", ml, entsize, count))
            }
            var out: [(String, UInt64)] = []
            for i in 0..<UInt64(count) {
                let e = ml + 8 + i * entsize
                if relative {
                    let nameOff = Int64(Int32(bitPattern: try word(at: e)))
                    let impOff = Int64(Int32(bitPattern: try word(at: e + 8)))
                    let selVA = UInt64(Int64(e) + nameOff)
                    let sel = directSelectors ? try cString(at: selVA) : try cString(at: try pointer(at: selVA))
                    out.append((sel, UInt64(Int64(e + 8) + impOff)))
                } else {
                    out.append((try cString(at: try pointer(at: e)), try pointer(at: e + 16)))
                }
            }
            return out
        }
    }
}

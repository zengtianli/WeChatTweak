import Foundation
import MachO

/// Builds a thin arm64 Mach-O carrying just enough Objective-C metadata for `UpdateLocator`:
/// `__objc_classlist` → one class (+ its metaclass) → `class_ro_t` → a method list whose IMPs
/// point at small code stubs in `__text`. Real-world shape by default (relative method list,
/// selectors via `__objc_selrefs`); flags switch to the absolute layout, direct selectors, and
/// chained-fixup-encoded pointers so every decoding branch is exercised.
enum ObjCFixture {
    static let baseVA: UInt64 = 0x1_0000_0000

    struct Method {
        let name: String
        /// Instruction words planted at the IMP (padded to 16 bytes).
        let code: [UInt32]
    }

    // Common instruction words.
    static let stpPrologue: UInt32 = 0xA9BB_6FFC   // stp x28, x27, [sp, #-0x50]!
    static let subSpPrologue: UInt32 = 0xD105_C3FF // sub sp, sp, #0x170
    static let ret: UInt32 = 0xD65F_03C0
    static let nop: UInt32 = 0xD503_201F
    static let movW0Zero: UInt32 = 0x5280_0000
    static func ldrbW0X0(_ field: UInt32) -> UInt32 { 0x3940_0000 | (field << 10) }  // ldrb w0, [x0, #field]
    static func strbW2X0(_ field: UInt32) -> UInt32 { 0x3900_0002 | (field << 10) }  // strb w2, [x0, #field]

    // Layout (file offset == VA - baseVA).
    private static let textOff = 0x400, nameOff = 0x800, selrefOff = 0xC00, constOff = 0xE00
    private static let roOff = 0x1000, metaRoOff = 0x1080, classOff = 0x1200, metaOff = 0x1240, listOff = 0x1400
    private static let fileSize = 0x1800
    private static let nsects = 6
    private static let headerSize = 32 + 72 + 80 * nsects

    /// Returns the file URL and the IMP VA of every method.
    static func write(className: String, methods: [Method], relative: Bool = true, directSelectors: Bool = false, chained: Bool = false) throws -> (url: URL, imps: [String: UInt64]) {
        precondition(methods.count <= 32 && headerSize <= textOff)
        var data = Data(count: fileSize)
        var imps: [String: UInt64] = [:]

        data.withUnsafeMutableBytes { raw in
            func put32(_ v: UInt32, _ at: Int) { raw.storeBytes(of: v.littleEndian, toByteOffset: at, as: UInt32.self) }
            func put64(_ v: UInt64, _ at: Int) { raw.storeBytes(of: v.littleEndian, toByteOffset: at, as: UInt64.self) }
            func putPtr(_ va: UInt64, _ at: Int) {
                // DYLD_CHAINED_PTR_64 rebase: target in bits 0–35; set a `next` bit so the mask path runs.
                put64(chained && va != 0 ? (va | (1 << 51)) : va, at)
            }
            func putStr(_ s: String, _ at: Int) -> Int {
                let bytes = Array(s.utf8) + [0]
                for (i, b) in bytes.enumerated() { raw.storeBytes(of: b, toByteOffset: at + i, as: UInt8.self) }
                return at + bytes.count
            }
            func putName16(_ s: String, _ at: Int) {
                for (i, b) in Array(s.utf8).prefix(16).enumerated() { raw.storeBytes(of: b, toByteOffset: at + i, as: UInt8.self) }
            }
            func va(_ off: Int) -> UInt64 { baseVA + UInt64(off) }

            // mach_header_64
            put32(MH_MAGIC_64, 0); put32(UInt32(CPU_TYPE_ARM64), 4); put32(0, 8); put32(UInt32(MH_DYLIB), 12)
            put32(1, 16); put32(UInt32(72 + 80 * nsects), 20); put32(0, 24); put32(0, 28)
            // one segment covering the file
            put32(UInt32(LC_SEGMENT_64), 32); put32(UInt32(72 + 80 * nsects), 36)
            putName16("__TEXT", 40)
            put64(baseVA, 56); put64(UInt64(fileSize), 64); put64(0, 72); put64(UInt64(fileSize), 80)
            put32(7, 88); put32(7, 92); put32(UInt32(nsects), 96); put32(0, 100)
            // sections: sectname[16] segname[16] addr size offset align reloff nreloc flags reserved1-3
            let sections: [(String, String, Int, Int)] = [
                ("__text", "__TEXT", textOff, 0x400),
                ("__objc_methname", "__TEXT", nameOff, 0x400),
                ("__objc_selrefs", "__DATA", selrefOff, 0x200),
                ("__objc_const", "__DATA", constOff, 0x400),
                ("__objc_data", "__DATA", classOff, 0x200),
                ("__objc_classlist", "__DATA", listOff, 0x100),
            ]
            for (i, s) in sections.enumerated() {
                let q = 32 + 72 + 80 * i
                putName16(s.0, q); putName16(s.1, q + 16)
                put64(va(s.2), q + 32); put64(UInt64(s.3), q + 40); put32(UInt32(s.2), q + 48)
            }

            // code stubs + selector strings + selrefs
            var strCursor = nameOff
            let classNameOff = strCursor
            strCursor = putStr(className, strCursor)
            var selStrOff: [Int] = []
            for (i, m) in methods.enumerated() {
                let imp = textOff + 16 * i
                for (k, w) in (m.code + Array(repeating: nop, count: 4)).prefix(4).enumerated() { put32(w, imp + 4 * k) }
                imps[m.name] = va(imp)
                selStrOff.append(strCursor)
                strCursor = putStr(m.name, strCursor)
                putPtr(va(selStrOff[i]), selrefOff + 8 * i)
            }

            // method list
            let count = methods.count
            if relative {
                put32(12 | 0x8000_0000 | (directSelectors ? 0x4000_0000 : 0), constOff); put32(UInt32(count), constOff + 4)
                for i in 0..<count {
                    let e = constOff + 8 + 12 * i
                    let nameTarget = directSelectors ? selStrOff[i] : selrefOff + 8 * i
                    put32(UInt32(bitPattern: Int32(nameTarget - e)), e)
                    put32(0, e + 4)
                    put32(UInt32(bitPattern: Int32((textOff + 16 * i) - (e + 8))), e + 8)
                }
            } else {
                put32(24, constOff); put32(UInt32(count), constOff + 4)
                for i in 0..<count {
                    let e = constOff + 8 + 24 * i
                    putPtr(va(selStrOff[i]), e); putPtr(0, e + 8); putPtr(va(textOff + 16 * i), e + 16)
                }
            }
            // class_ro_t: flags instanceStart instanceSize reserved ivarLayout name baseMethods ...
            putPtr(va(classNameOff), roOff + 24); putPtr(va(constOff), roOff + 32)
            putPtr(va(classNameOff), metaRoOff + 24); putPtr(0, metaRoOff + 32)
            // class_t: isa superclass cache vtable data
            putPtr(va(metaOff), classOff); putPtr(va(roOff), classOff + 32)
            putPtr(0, metaOff); putPtr(va(metaRoOff), metaOff + 32)
            // classlist
            putPtr(va(classOff), listOff)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechattweak-objc-fixture-\(UUID().uuidString).dylib")
        try data.write(to: url)
        return (url, imps)
    }

    /// The eight XAppUpdateManager methods in their pristine shape (fields 0x18 / 0x19 like 4.1.x), plus a decoy.
    static func pristineUpdateMethods(getterField: UInt32 = 0x18, setterField: UInt32? = nil) -> [Method] {
        let sf = setterField ?? getterField
        return [
            Method(name: "startUpdater", code: [stpPrologue]),
            Method(name: "checkForUpdates:", code: [subSpPrologue]),
            Method(name: "startBackgroundUpdatesCheck:", code: [subSpPrologue]),
            Method(name: "enableAutoUpdate:", code: [stpPrologue]),
            Method(name: "automaticallyDownloadsUpdates", code: [ldrbW0X0(getterField), ret]),
            Method(name: "setAutomaticallyDownloadsUpdates:", code: [strbW2X0(sf), ret]),
            Method(name: "canCheckForUpdate", code: [ldrbW0X0(getterField + 1), ret]),
            Method(name: "setCanCheckForUpdate:", code: [strbW2X0(sf + 1), ret]),
            Method(name: "sparkleUpdater", code: [stpPrologue]),
        ]
    }
}

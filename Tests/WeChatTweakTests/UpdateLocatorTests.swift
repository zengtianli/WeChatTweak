import XCTest
@testable import WeChatTweak

final class UpdateLocatorTests: XCTestCase {
    private let cls = UpdateLocator.className

    private func expectedOrder() -> [String] {
        UpdateLocator.retMethods + UpdateLocator.zeroAccessors.flatMap { [$0.getter, $0.setter] }
    }

    /// Real-world layout: relative method list, selectors through __objc_selrefs.
    func testLocatesAllEightFromRelativeMethodList() throws {
        let fx = try ObjCFixture.write(className: cls, methods: ObjCFixture.pristineUpdateMethods())
        defer { try? FileManager.default.removeItem(at: fx.url) }
        let hits = try UpdateLocator.locate(binary: fx.url)

        XCTAssertEqual(hits.map(\.method), expectedOrder())
        for hit in hits {
            XCTAssertEqual(hit.va, fx.imps[hit.method], hit.method)
            XCTAssertFalse(hit.alreadyPatched, hit.method)
            XCTAssertEqual(hit.entry.addr, hit.va)
        }
        // ret methods: 4-byte prologue → ret
        for hit in hits.prefix(4) {
            XCTAssertEqual(hit.entry.asm.count, 4, hit.method)
            XCTAssertEqual(hit.entry.asm, Data([0xC0, 0x03, 0x5F, 0xD6]), hit.method)
            XCTAssertEqual(hit.entry.expected.count, 1)
            XCTAssertNotEqual(hit.entry.expected[0], hit.entry.asm, "expected must be the pristine prologue, not the patch")
        }
        // getter: 8 bytes ldrb+ret → mov w0,#0 + ret ; setter: 4 bytes strb → ret
        let getter = hits[4], setter = hits[5]
        XCTAssertEqual(getter.entry.asm, Data([0x00, 0x00, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6]))
        XCTAssertEqual(getter.entry.expected[0], Data([0x00, 0x60, 0x40, 0x39, 0xC0, 0x03, 0x5F, 0xD6]))  // ldrb w0,[x0,#0x18]; ret
        XCTAssertEqual(setter.entry.asm, Data([0xC0, 0x03, 0x5F, 0xD6]))
        XCTAssertEqual(setter.entry.expected[0], Data([0x02, 0x60, 0x00, 0x39]))                            // strb w2,[x0,#0x18]
    }

    /// Absolute method list + direct selectors + chained-fixup pointer encoding all decode the same.
    func testAbsoluteListDirectSelectorsAndChainedPointers() throws {
        let fx = try ObjCFixture.write(className: cls, methods: ObjCFixture.pristineUpdateMethods(), relative: false, chained: true)
        defer { try? FileManager.default.removeItem(at: fx.url) }
        let hits = try UpdateLocator.locate(binary: fx.url)
        XCTAssertEqual(hits.map(\.va), expectedOrder().map { fx.imps[$0]! })

        let fx2 = try ObjCFixture.write(className: cls, methods: ObjCFixture.pristineUpdateMethods(), relative: true, directSelectors: true, chained: true)
        defer { try? FileManager.default.removeItem(at: fx2.url) }
        XCTAssertEqual(try UpdateLocator.locate(binary: fx2.url).map(\.va), expectedOrder().map { fx2.imps[$0]! })
    }

    /// The located entries must round-trip through Patcher: apply, then re-locate reports "already patched".
    func testEntriesPatchAndRelocateAsAlreadyPatched() throws {
        let fx = try ObjCFixture.write(className: cls, methods: ObjCFixture.pristineUpdateMethods())
        defer { try? FileManager.default.removeItem(at: fx.url) }
        let entries = try UpdateLocator.locate(binary: fx.url).map(\.entry)
        try Patcher.patch(binary: fx.url, entries: entries)

        let again = try UpdateLocator.locate(binary: fx.url)
        XCTAssertEqual(again.count, 8)
        XCTAssertTrue(again.allSatisfy(\.alreadyPatched))
        for hit in again { XCTAssertEqual(hit.entry.expected, [hit.entry.asm], hit.method) }
        // and inspect agrees
        XCTAssertTrue(try Patcher.inspect(binary: fx.url, entries: entries).allSatisfy { $0.state == .patched })
    }

    func testMissingMethodThrows() throws {
        let methods = ObjCFixture.pristineUpdateMethods().filter { $0.name != "enableAutoUpdate:" }
        let fx = try ObjCFixture.write(className: cls, methods: methods)
        defer { try? FileManager.default.removeItem(at: fx.url) }
        XCTAssertThrowsError(try UpdateLocator.locate(binary: fx.url)) { error in
            guard case UpdateLocator.Error.methodsMissing(let names) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(names, ["enableAutoUpdate:"])
        }
    }

    func testWrongClassNameThrows() throws {
        let fx = try ObjCFixture.write(className: "XAppSomethingElse", methods: ObjCFixture.pristineUpdateMethods())
        defer { try? FileManager.default.removeItem(at: fx.url) }
        XCTAssertThrowsError(try UpdateLocator.locate(binary: fx.url)) { error in
            guard case UpdateLocator.Error.classNotFound = error else { return XCTFail("got \(error)") }
        }
    }

    /// Same selector, different code → refuse (WeChat changed the implementation).
    func testUnexpectedEntryCodeThrows() throws {
        var methods = ObjCFixture.pristineUpdateMethods()
        methods[0] = ObjCFixture.Method(name: "startUpdater", code: [ObjCFixture.nop])  // not a prologue
        let fx = try ObjCFixture.write(className: cls, methods: methods)
        defer { try? FileManager.default.removeItem(at: fx.url) }
        XCTAssertThrowsError(try UpdateLocator.locate(binary: fx.url)) { error in
            guard case UpdateLocator.Error.unexpectedCode(let m, _, _, _) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(m, "startUpdater")
        }
    }

    func testAccessorFieldMismatchThrows() throws {
        let fx = try ObjCFixture.write(className: cls, methods: ObjCFixture.pristineUpdateMethods(getterField: 0x18, setterField: 0x30))
        defer { try? FileManager.default.removeItem(at: fx.url) }
        XCTAssertThrowsError(try UpdateLocator.locate(binary: fx.url)) { error in
            guard case UpdateLocator.Error.accessorFieldMismatch = error else { return XCTFail("got \(error)") }
        }
    }
}

import XCTest
@testable import WeChatTweak

final class PatcherTests: XCTestCase {
    private let size = 0x2000
    private let plant = 0x800
    private var va: UInt64 { MachOFixture.baseVA + UInt64(plant) }

    func testPatchWritesAndIsIdempotent() throws {
        let url = try MachOFixture.write(size: size, words: [plant: MachOFixture.word("40100034")])
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = try Config.Entry(arch: .arm64, addr: va, asmHex: "82000014", expectedHex: ["40100034"])

        try Patcher.patch(binary: url, entries: [entry])
        XCTAssertEqual(try MachOFixture.word(at: plant, in: url), MachOFixture.word("82000014"))

        // Second run: already patched → skip, no throw, bytes unchanged.
        try Patcher.patch(binary: url, entries: [entry])
        XCTAssertEqual(try MachOFixture.word(at: plant, in: url), MachOFixture.word("82000014"))
    }

    /// The whole safety story: wrong build → bytes differ from `expected` → refuse, touch nothing.
    func testExpectedMismatchRefusesToWrite() throws {
        let url = try MachOFixture.write(size: size, words: [plant: MachOFixture.word("DEADBEEF")])
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = try Config.Entry(arch: .arm64, addr: va, asmHex: "82000014", expectedHex: ["40100034"])

        XCTAssertThrowsError(try Patcher.patch(binary: url, entries: [entry])) { error in
            guard case Patcher.Error.expectedMismatch = error else { return XCTFail("expected expectedMismatch, got \(error)") }
        }
        XCTAssertEqual(try MachOFixture.word(at: plant, in: url), MachOFixture.word("DEADBEEF"))
    }

    /// `expected` may list several accepted states (pristine + already-silent) — keeptip's first entry relies on it.
    func testExpectedAcceptsAnyListedVariant() throws {
        let url = try MachOFixture.write(size: size, words: [plant: MachOFixture.word("82000014")])
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = try Config.Entry(arch: .arm64, addr: va, asmHex: "40100034", expectedHex: ["40100034", "82000014"])
        try Patcher.patch(binary: url, entries: [entry])
        XCTAssertEqual(try MachOFixture.word(at: plant, in: url), MachOFixture.word("40100034"))
    }

    func testVAOutsideSegmentsIsRejected() throws {
        let url = try MachOFixture.write(size: size, words: [:])
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = try Config.Entry(arch: .arm64, addr: 0x7fff_0000_0000, asmHex: "82000014", expectedHex: [])
        XCTAssertThrowsError(try Patcher.patch(binary: url, entries: [entry])) { error in
            guard case Patcher.Error.vaNotFound = error else { return XCTFail("expected vaNotFound, got \(error)") }
        }
    }
}

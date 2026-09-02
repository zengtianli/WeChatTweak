import XCTest
@testable import WeChatTweak

final class RevokeLocatorTests: XCTestCase {
    private let size = 0x4000
    private let plant = 0x1000  // file offset of the planted cbz (== VA - baseVA)

    /// Every tabulated generation must be found, uniquely, from a pristine binary.
    func testEachGenerationHitsUniquely() throws {
        for sig in RevokeLocator.signatures {
            let url = try MachOFixture.write(size: size, words: [
                plant: sig.cbzWord,
                plant + Int(sig.delta): MachOFixture.word(sig.strX0Hex),
            ])
            defer { try? FileManager.default.removeItem(at: url) }
            let hit = try RevokeLocator.locate(binary: url)
            XCTAssertEqual(hit.signature, sig, sig.name)
            XCTAssertEqual(hit.silentVA, MachOFixture.baseVA + UInt64(plant), sig.name)
            XCTAssertEqual(hit.keeptipVA, hit.silentVA + sig.delta, sig.name)
        }
    }

    /// A machine that already ran `--variant silent` has `b` at anchor 1 and must still locate.
    func testAlreadySilentPatchedStillHits() throws {
        let sig = RevokeLocator.signatures[0]
        let url = try MachOFixture.write(size: size, words: [
            plant: sig.branchWord,
            plant + Int(sig.delta): MachOFixture.word(sig.strXzrHex),  // and keeptip already applied
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let hit = try RevokeLocator.locate(binary: url)
        XCTAssertEqual(hit.silentVA, MachOFixture.baseVA + UInt64(plant))
    }

    /// cbz present but the newmsgid store missing → not a hit (anchor 2 is mandatory).
    func testLoneCbzIsNoHit() throws {
        let sig = RevokeLocator.signatures[0]
        let url = try MachOFixture.write(size: size, words: [plant: sig.cbzWord])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try RevokeLocator.locate(binary: url)) { error in
            guard case RevokeLocator.Error.noHit = error else { return XCTFail("expected noHit, got \(error)") }
        }
    }

    /// Two plants → refuse to guess.
    func testTwoHitsAreAmbiguous() throws {
        let sig = RevokeLocator.signatures[0]
        let second = plant + 0x1000
        let url = try MachOFixture.write(size: size, words: [
            plant: sig.cbzWord, plant + Int(sig.delta): MachOFixture.word(sig.strX0Hex),
            second: sig.cbzWord, second + Int(sig.delta): MachOFixture.word(sig.strX0Hex),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try RevokeLocator.locate(binary: url)) { error in
            guard case let RevokeLocator.Error.ambiguous(count, _) = error else { return XCTFail("expected ambiguous, got \(error)") }
            XCTAssertEqual(count, 2)
        }
    }

    /// The derived keeptip entries restore the cbz (accepting an applied `b`) and zero newmsgid.
    func testKeeptipEntriesFollowGeneration() throws {
        let sig = RevokeLocator.signatures[0]
        let result = RevokeLocator.Result(silentVA: 0x1234_0000, signature: sig)
        let entries = try RevokeLocator.keeptipEntries(from: result)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].addr, 0x1234_0000)
        XCTAssertEqual(entries[0].asm.map { String(format: "%02X", $0) }.joined(), sig.cbzHex)
        XCTAssertEqual(entries[0].expected.map { $0.map { String(format: "%02X", $0) }.joined() }, [sig.cbzHex, sig.branchHex])
        XCTAssertEqual(entries[1].addr, 0x1234_0000 + sig.delta)
        XCTAssertEqual(entries[1].asm.map { String(format: "%02X", $0) }.joined(), sig.strXzrHex)
    }
}

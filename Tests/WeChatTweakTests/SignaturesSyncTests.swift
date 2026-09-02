import XCTest
@testable import WeChatTweak

/// `signatures.json` is the SSOT shared with tools/locate_revoke.py; the Swift table is
/// generated from it. This test is the fail-closed gate that the two never drift.
final class SignaturesSyncTests: XCTestCase {
    private struct Doc: Decodable {
        struct Gen: Decodable {
            let name: String, builds: String, cbz: String, b: String, delta: String, str_x0: String, str_xzr: String, field: String
        }
        let off_cbz: String
        let generations: [Gen]
    }

    private func repoRoot() -> URL {
        // Tests/WeChatTweakTests/<file> → repo root
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testGeneratedTableMatchesJSON() throws {
        let url = repoRoot().appendingPathComponent("signatures.json")
        let doc = try JSONDecoder().decode(Doc.self, from: Data(contentsOf: url))
        XCTAssertEqual(UInt64(doc.off_cbz.dropFirst(2), radix: 16), RevokeLocator.offCbz)
        XCTAssertEqual(doc.generations.count, RevokeLocator.signatures.count, "generation count drifted — run tools/gen_signatures.py")
        for (g, s) in zip(doc.generations, RevokeLocator.signatures) {
            XCTAssertEqual(g.name, s.name)
            XCTAssertEqual(g.builds, s.builds)
            XCTAssertEqual(g.cbz, s.cbzHex)
            XCTAssertEqual(g.b, s.branchHex)
            XCTAssertEqual(UInt64(g.delta.dropFirst(2), radix: 16), s.delta)
            XCTAssertEqual(g.str_x0, s.strX0Hex)
            XCTAssertEqual(g.str_xzr, s.strXzrHex)
            XCTAssertEqual(UInt64(g.field.dropFirst(2), radix: 16), s.field)
        }
    }

    /// Each generation must be internally consistent: `b` jumps where the `cbz` jumped,
    /// and `str xzr` differs from `str x0` only in Rt (=31).
    func testGenerationsAreSelfConsistent() {
        for s in RevokeLocator.signatures {
            let cbz = s.cbzWord, b = s.branchWord
            XCTAssertEqual(cbz & 0xFF00_0000, 0x3400_0000, "\(s.name): anchor 1 must be cbz w")
            XCTAssertEqual(cbz & 0x1F, 0, "\(s.name): cbz must test w0")
            XCTAssertEqual(b & 0xFC00_0000, 0x1400_0000, "\(s.name): silent asm must be b")
            XCTAssertEqual((cbz >> 5) & 0x7FFFF, b & 0x3FF_FFFF, "\(s.name): b target != cbz target")
            let x0 = RevokeLocator.Signature.word(s.strX0Hex), xzr = RevokeLocator.Signature.word(s.strXzrHex)
            XCTAssertEqual(x0 & 0xFFC0_0000, 0xF900_0000, "\(s.name): anchor 2 must be str x,[x,#imm]")
            XCTAssertEqual(x0 & 0x3E0, 19 << 5, "\(s.name): base must be x19")
            XCTAssertEqual(x0 & 0x1F, 0, "\(s.name): pristine store is x0")
            XCTAssertEqual(xzr & 0x1F, 31, "\(s.name): keeptip store is xzr")
            XCTAssertEqual(x0 & ~0x1F, xzr & ~0x1F, "\(s.name): str xzr must differ from str x0 only in Rt")
            XCTAssertEqual(UInt64((x0 >> 10) & 0xFFF) * 8, s.field, "\(s.name): field offset != str imm")
        }
    }
}

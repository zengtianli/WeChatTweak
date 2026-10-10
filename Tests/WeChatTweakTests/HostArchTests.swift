import XCTest
@testable import WeChatTweak

/// A universal wechat.dylib has two slices and a Mac runs one of them. With arm64-only patch
/// points, an Intel Mac used to get "applied" and a green doctor while WeChat went on
/// deleting recalled messages (WeChatTweak issue #7). The engine must not write, and must
/// not claim protection, for an architecture it has no patch points for.
final class HostArchTests: XCTestCase {
    private let plant = 0x800
    private var va: UInt64 { MachOFixture.baseVA + UInt64(plant) }

    private func bundle() throws -> URL {
        let fixture = try MachOFixture.write(size: 0x2000, words: [plant: MachOFixture.word("40100034")])
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechattweak-arch-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture, to: app.appendingPathComponent(Command.dylibBinary))
        return app
    }

    private func config() throws -> Config {
        let entry = try Config.Entry(arch: .arm64, addr: va, asmHex: "82000014", expectedHex: ["40100034"])
        return Config(version: "270134", targets: [Config.Target(identifier: "revoke", entries: [entry], binary: Command.dylibBinary)])
    }

    func testArm64OnlyPointsAreNotWrittenOnIntel() throws {
        let app = try bundle()
        defer { try? FileManager.default.removeItem(at: app) }
        XCTAssertThrowsError(try Command.patchFeatures(app: app, config: try config(), blockUpdate: false, hostArch: .x86_64)) { error in
            guard case let Command.Error.nothingApplied(lines) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(lines.joined().contains("no x86_64 patch points"), lines.joined(separator: "\n"))
        }
        let word = try MachOFixture.word(at: plant, in: app.appendingPathComponent(Command.dylibBinary))
        XCTAssertEqual(word, MachOFixture.word("40100034"), "the arm64 slice must be left alone on an Intel Mac")
    }

    func testSamePointsApplyOnAppleSilicon() throws {
        let app = try bundle()
        defer { try? FileManager.default.removeItem(at: app) }
        let outcome = try Command.patchFeatures(app: app, config: try config(), blockUpdate: false, hostArch: .arm64)
        XCTAssertNotNil(outcome.applied[.antiRevoke])
        let word = try MachOFixture.word(at: plant, in: app.appendingPathComponent(Command.dylibBinary))
        XCTAssertEqual(word, MachOFixture.word("82000014"))
    }

    func testSupportsLooksAtEntriesNotAtTheBuildNumber() throws {
        let targets = try config().targets
        XCTAssertTrue(Command.supports(.arm64, targets))
        XCTAssertFalse(Command.supports(.x86_64, targets))
    }
}

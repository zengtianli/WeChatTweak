import XCTest
@testable import WeChatTweak

/// `restore` is the one command that writes bytes *back* into someone's WeChat, so these
/// tests are deliberately adversarial: it must undo exactly what `patch` wrote, be harmless
/// when run twice, and refuse rather than guess when config.json never recorded what the
/// original bytes were.
///
/// They drive `Command.restore` itself — not a re-implementation of its inversion rule.
/// A test that re-derives "what restore probably does" would stay green while the real
/// thing rots, which is worse than no test.
final class RestoreTests: XCTestCase {
    private let size = 0x2000
    private let plant = 0x800
    private var va: UInt64 { MachOFixture.baseVA + UInt64(plant) }

    /// A throwaway `.app` whose `Contents/MacOS/WeChat` is a fixture Mach-O, so the
    /// bundle-relative path resolution in `Command.restore` is exercised for real.
    private func bundle(word hex: String) throws -> URL {
        let fixture = try MachOFixture.write(size: size, words: [plant: MachOFixture.word(hex)])
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechattweak-bundle-\(UUID().uuidString).app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture, to: macos.appendingPathComponent("WeChat"))
        return app
    }

    private func binary(in app: URL) -> URL {
        app.appendingPathComponent(Command.defaultBinary)
    }

    private func config(_ entries: [Config.Entry], identifier: String = "revoke") -> Config {
        Config(version: "269627", targets: [Config.Target(identifier: identifier, entries: entries, binary: nil)])
    }

    /// patch → restore must land back on the exact original word.
    func testRestoreUndoesPatch() throws {
        let app = try bundle(word: "40100034")
        defer { try? FileManager.default.removeItem(at: app) }
        let entry = try Config.Entry(arch: .arm64, addr: va, asmHex: "82000014", expectedHex: ["40100034"])

        try Patcher.patch(binary: binary(in: app), entries: [entry])
        XCTAssertEqual(try MachOFixture.word(at: plant, in: binary(in: app)), MachOFixture.word("82000014"))

        let touched = try Command.restore(app: app, config: config([entry]))
        XCTAssertEqual(touched, [Command.defaultBinary])
        XCTAssertEqual(try MachOFixture.word(at: plant, in: binary(in: app)), MachOFixture.word("40100034"))
    }

    /// Twice in a row is a no-op, not an "unexpected bytes" failure.
    func testRestoreIsIdempotent() throws {
        let app = try bundle(word: "82000014")
        defer { try? FileManager.default.removeItem(at: app) }
        let entry = try Config.Entry(arch: .arm64, addr: va, asmHex: "82000014", expectedHex: ["40100034"])

        try Command.restore(app: app, config: config([entry]))
        try Command.restore(app: app, config: config([entry]))
        XCTAssertEqual(try MachOFixture.word(at: plant, in: binary(in: app)), MachOFixture.word("40100034"))
    }

    /// keeptip's first entry lists several accepted states; `expected[0]` is the pristine one.
    func testRestorePicksFirstExpectedAsPristine() throws {
        let app = try bundle(word: "82000014")
        defer { try? FileManager.default.removeItem(at: app) }
        let entry = try Config.Entry(arch: .arm64, addr: va, asmHex: "40100034", expectedHex: ["40100034", "82000014"])

        try Command.restore(app: app, config: config([entry], identifier: "revoke-keeptip"))
        XCTAssertEqual(try MachOFixture.word(at: plant, in: binary(in: app)), MachOFixture.word("40100034"))
    }

    /// Foreign bytes (another tool's patch, or a build mismatch) → refuse, touch nothing.
    func testRestoreRefusesForeignBytes() throws {
        let app = try bundle(word: "DEADBEEF")
        defer { try? FileManager.default.removeItem(at: app) }
        let entry = try Config.Entry(arch: .arm64, addr: va, asmHex: "82000014", expectedHex: ["40100034"])

        XCTAssertThrowsError(try Command.restore(app: app, config: config([entry]))) { error in
            guard case Patcher.Error.expectedMismatch = error else { return XCTFail("expected expectedMismatch, got \(error)") }
        }
        XCTAssertEqual(try MachOFixture.word(at: plant, in: binary(in: app)), MachOFixture.word("DEADBEEF"))
    }

    /// The five WeChat 3.8.x builds carry no `expected`. There is no original to write back,
    /// so restore must fail loudly — and before writing anything.
    func testRestoreRefusesWhenConfigRecordsNoOriginal() throws {
        let app = try bundle(word: "00008052")
        defer { try? FileManager.default.removeItem(at: app) }
        let entry = try Config.Entry(arch: .arm64, addr: va, asmHex: "00008052", expectedHex: [])

        XCTAssertThrowsError(try Command.restore(app: app, config: config([entry]))) { error in
            guard case Command.Error.restoreUnavailable(_, let targets) = error else {
                return XCTFail("expected restoreUnavailable, got \(error)")
            }
            XCTAssertEqual(targets, ["revoke"])
        }
        XCTAssertEqual(try MachOFixture.word(at: plant, in: binary(in: app)), MachOFixture.word("00008052"))
    }

    /// A config whose *second* target lacks `expected` must abort before the first one is
    /// written — a half-restored binary is worse than a patched one.
    func testRestoreRefusesBeforeTouchingAnythingWhenAnyTargetIsUnrecoverable() throws {
        let app = try bundle(word: "82000014")
        defer { try? FileManager.default.removeItem(at: app) }
        let good = try Config.Entry(arch: .arm64, addr: va, asmHex: "82000014", expectedHex: ["40100034"])
        let bad = try Config.Entry(arch: .arm64, addr: va, asmHex: "00008052", expectedHex: [])
        let cfg = Config(version: "269627", targets: [
            Config.Target(identifier: "revoke", entries: [good], binary: nil),
            Config.Target(identifier: "multiInstance", entries: [bad], binary: nil),
        ])

        XCTAssertThrowsError(try Command.restore(app: app, config: cfg))
        // Still patched — nothing was written.
        XCTAssertEqual(try MachOFixture.word(at: plant, in: binary(in: app)), MachOFixture.word("82000014"))
    }
}

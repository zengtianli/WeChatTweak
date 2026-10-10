import XCTest
@testable import WeChatTweak

/// "Permission denied" has five unrelated causes, each with its own fix (issue #1 collected
/// users being sent to App Management for a bundle that was merely root-owned or locked).
/// These drive `WriteAccess` and the real `Command.patchFeatures` write path on a throwaway
/// bundle put into each state for real — chmod, chflags, an ACL — not on mocked stat results.
final class WriteAccessTests: XCTestCase {
    private let plant = 0x800
    private var va: UInt64 { MachOFixture.baseVA + UInt64(plant) }

    private func bundle() throws -> URL {
        let fixture = try MachOFixture.write(size: 0x2000, words: [plant: MachOFixture.word("40100034")])
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechattweak-access-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture, to: app.appendingPathComponent(Command.dylibBinary))
        return app
    }

    private func dylib(_ app: URL) -> URL { app.appendingPathComponent(Command.dylibBinary) }

    private func config() throws -> Config {
        let entry = try Config.Entry(arch: .arm64, addr: va, asmHex: "82000014", expectedHex: ["40100034"])
        return Config(version: "270134", targets: [Config.Target(identifier: "revoke", entries: [entry], binary: Command.dylibBinary)])
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Runs the real patch and returns the failure summary it prints for a refused write.
    private func refusedPatch(_ app: URL) throws -> [String] {
        var summary: [String] = []
        XCTAssertThrowsError(try Command.patchFeatures(app: app, config: try config(), blockUpdate: false, hostArch: .arm64)) { error in
            guard case let Command.Error.nothingApplied(lines) = error else { return XCTFail("\(error)") }
            summary = lines
        }
        XCTAssertEqual(try MachOFixture.word(at: plant, in: dylib(app)), MachOFixture.word("40100034"), "a refused write must leave the bytes alone")
        return summary
    }

    func testCleanBundleHasNoBlockers() throws {
        let app = try bundle()
        defer { try? FileManager.default.removeItem(at: app) }
        XCTAssertEqual(WriteAccess.inspect(app: app), WriteAccess.Report(blockers: [], items: []))
    }

    func testReadOnlyModeIsNeedsAdminNotAppManagement() throws {
        let app = try bundle()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dylib(app).path)
            try? FileManager.default.removeItem(at: app)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dylib(app).path)

        let report = WriteAccess.inspect(app: app)
        XCTAssertEqual(report.blockers, [.needsAdmin])
        XCTAssertEqual(report.items.map(\.path), [dylib(app).path])
        XCTAssertEqual(report.items.first?.mode, "444")
        // Root is never short of POSIX write access.
        XCTAssertEqual(WriteAccess.inspect(app: app, uid: 0).blockers, [])

        let summary = try refusedPatch(app)
        XCTAssertTrue(summary.contains("Write blocked: needsAdmin"), summary.joined(separator: "\n"))
        XCTAssertFalse(summary.joined().contains("App Management"))
    }

    func testFinderLockIsImmutable() throws {
        let app = try bundle()
        defer {
            _ = try? run("/usr/bin/chflags", ["nouchg", dylib(app).path])
            try? FileManager.default.removeItem(at: app)
        }
        XCTAssertEqual(try run("/usr/bin/chflags", ["uchg", dylib(app).path]), 0)

        let report = WriteAccess.inspect(app: app)
        XCTAssertEqual(report.blockers, [.immutable])
        XCTAssertEqual(report.items.first?.flags, ["uchg"])
        // The lock holds for root too, which is why "enter your password" is the wrong advice.
        XCTAssertEqual(WriteAccess.inspect(app: app, uid: 0).blockers, [.immutable])
        XCTAssertTrue(WriteAccess.advice(report, app: app).first?.contains("chflags -R nouchg") ?? false)

        let summary = try refusedPatch(app)
        XCTAssertTrue(summary.contains("Write blocked: immutable"), summary.joined(separator: "\n"))
    }

    func testDenyACLIsReported() throws {
        let app = try bundle()
        defer {
            _ = try? run("/bin/chmod", ["-N", dylib(app).path])
            try? FileManager.default.removeItem(at: app)
        }
        XCTAssertEqual(try run("/bin/chmod", ["+a", "everyone deny write,append", dylib(app).path]), 0)

        let report = WriteAccess.inspect(app: app)
        XCTAssertEqual(report.blockers, [.aclDeny])
        XCTAssertEqual(report.items.first?.aclDeny, true)

        let summary = try refusedPatch(app)
        XCTAssertTrue(summary.contains("Write blocked: aclDeny"), summary.joined(separator: "\n"))
    }

    /// An allow entry, or a deny entry for something the patch does not do, is not a blocker.
    func testUnrelatedACLIsIgnored() throws {
        let app = try bundle()
        defer {
            _ = try? run("/bin/chmod", ["-N", dylib(app).path])
            try? FileManager.default.removeItem(at: app)
        }
        XCTAssertEqual(try run("/bin/chmod", ["+a", "everyone allow read", dylib(app).path]), 0)
        XCTAssertEqual(try run("/bin/chmod", ["+a", "everyone deny readextattr", dylib(app).path]), 0)
        XCTAssertEqual(WriteAccess.inspect(app: app).blockers, [])
    }

    /// A refusal the filesystem cannot explain is App Management — and only a refusal that
    /// actually happened: `inspect` alone never produces it.
    func testUnexplainedRefusalIsAppManagement() throws {
        let app = try bundle()
        defer { try? FileManager.default.removeItem(at: app) }
        let refusal = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        let explained = try XCTUnwrap(WriteAccess.explain(refusal, app: app))
        XCTAssertEqual(explained.report.blockers, [.appManagement])
        XCTAssertTrue(explained.lines.first?.contains("App Management") ?? false)
        XCTAssertEqual(WriteAccess.summaryLines(refusal, app: app).first, "Write blocked: appManagement")
        XCTAssertFalse(WriteAccess.inspect(app: app).blockers.contains(.appManagement))
    }

    /// A wrong-build byte mismatch is not a permission problem and must not be dressed as one.
    func testNonPermissionFailureGetsNoDiagnosis() throws {
        let app = try bundle()
        defer { try? FileManager.default.removeItem(at: app) }
        let mismatch = Patcher.Error.expectedMismatch(arch: "arm64", va: va, found: "00000000", want: ["40100034"])
        XCTAssertNil(WriteAccess.explain(mismatch, app: app))
        XCTAssertEqual(WriteAccess.summaryLines(mismatch, app: app), [])
    }
}

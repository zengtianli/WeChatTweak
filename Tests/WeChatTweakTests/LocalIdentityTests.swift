import XCTest
@testable import WeChatTweak

/// WeChatUnrevoke #13: after patching, WeChat said "录屏权限未开启" although System Settings
/// showed the switch ON. macOS binds the grant to the designated requirement; an ad-hoc
/// re-sign makes that `cdhash H"…"`, which moves with every content change (silent ↔ keeptip,
/// a WeChat update re-patched). Signed with this Mac's identity it must stay put.
final class LocalIdentityTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("wt-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        setenv("WECHATTWEAK_SIGNING_DIR", base.appendingPathComponent("signing").path, 1)
        setenv("WECHATTWEAK_KEEP_PRIVACY_GRANTS", "1", 1)
    }

    override func tearDownWithError() throws {
        unsetenv("WECHATTWEAK_SIGNING_DIR")
        unsetenv("WECHATTWEAK_KEEP_PRIVACY_GRANTS")
        Resigner.identity = nil
        try? FileManager.default.removeItem(at: base)
    }

    /// A minimal bundle with a nested "dylib" whose bytes we change between signings,
    /// like silent ↔ keeptip changes wechat.dylib.
    private func makeApp() throws -> URL {
        let fm = FileManager.default
        let app = base.appendingPathComponent("Fixture.app", isDirectory: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Fixture").path)
        let info: [String: Any] = ["CFBundleExecutable": "Fixture", "CFBundleIdentifier": "test.wechattweak.identity"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("variant-a".utf8).write(to: app.appendingPathComponent("Contents/Resources/payload.bin"))
        return app
    }

    private func changePayload(_ app: URL, _ text: String) throws {
        try Data(text.utf8).write(to: app.appendingPathComponent("Contents/Resources/payload.bin"))
    }

    func testAdhocRequirementMovesWithContent() async throws {
        let app = try makeApp()
        try await Command.resign(app: app, signing: .adhoc)
        let first = try XCTUnwrap(Command.designatedRequirement(of: app))
        XCTAssertTrue(first.contains("cdhash"), first)
        try changePayload(app, "variant-b")
        try await Command.resign(app: app, signing: .adhoc)
        XCTAssertNotEqual(first, Command.designatedRequirement(of: app), "this is why the grant went stale")
    }

    func testLocalIdentityRequirementSurvivesContentChanges() async throws {
        let app = try makeApp()
        try await Command.resign(app: app, signing: .local)
        let first = try XCTUnwrap(Command.designatedRequirement(of: app))
        // identifier (preserved from the original signature) + this Mac's certificate; no cdhash.
        XCTAssertTrue(first.hasPrefix("identifier \"") && first.contains(" and certificate leaf = H\""), first)
        XCTAssertFalse(first.contains("cdhash"), first)
        try changePayload(app, "variant-b")
        try await Command.resign(app: app, signing: .local)
        XCTAssertEqual(first, Command.designatedRequirement(of: app))
        try changePayload(app, "variant-a")
        try await Command.resign(app: app, signing: .local)
        XCTAssertEqual(first, Command.designatedRequirement(of: app))

        // Created once, reused afterwards; never added to the keychain search list.
        let identity = try XCTUnwrap(LocalIdentity.existing())
        XCTAssertTrue(first.contains(identity.sha1.lowercased()), "requirement names this Mac's certificate")
        let list = LocalIdentity.capture("/usr/bin/security", ["list-keychains", "-d", "user"]).output
        XCTAssertFalse(list.contains(identity.keychain.path), "identity keychain must stay out of the search list")
        let verify = LocalIdentity.capture("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        XCTAssertEqual(verify.status, 0, verify.output)
    }
}

/// The post-sign gate must tell a binary macOS would refuse from one it accepts, without
/// running either (the #4 shape: ad-hoc + a restricted com.apple.developer.* entitlement).
final class LaunchProbeTests: XCTestCase {
    private func signedCopy(entitlements: [String: Any]?) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent("bin")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: exe.path)
        var args = ["-f", "-s", "-", "-o", "runtime"]
        if let entitlements {
            let ent = dir.appendingPathComponent("e.plist")
            try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: ent)
            args += ["--entitlements", ent.path]
        }
        XCTAssertEqual(LocalIdentity.capture("/usr/bin/codesign", args + [exe.path]).status, 0)
        return (dir, exe)
    }

    func testAcceptedBinaryPasses() throws {
        let (dir, exe) = try signedCopy(entitlements: ["com.apple.application-identifier": "5A4RE8SF68.com.tencent.xinWeChat"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(LaunchProbe.probe(exe))
    }

    func testRefusedBinaryIsCaught() throws {
        let (dir, exe) = try signedCopy(entitlements: ["com.apple.developer.team-identifier": "5A4RE8SF68",
                                                       "com.apple.application-identifier": "5A4RE8SF68.x"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNotNil(LaunchProbe.probe(exe))
    }
}

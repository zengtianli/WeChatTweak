import XCTest
@testable import WeChatTweak

/// WeChatTweak #11: a second WeChat next to the first one. A copy only works when its bundle
/// identifier AND its signature identifier are its own, and when it no longer carries the
/// entitlements that tie it to Tencent's sandbox container (see Clone.swift).
final class CloneTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("wt-clone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        setenv("WECHATTWEAK_SIGNING_DIR", base.appendingPathComponent("signing").path, 1)
        setenv("WECHATTWEAK_KEEP_PRIVACY_GRANTS", "1", 1)
    }

    override func tearDownWithError() throws {
        unsetenv("WECHATTWEAK_SIGNING_DIR")
        unsetenv("WECHATTWEAK_KEEP_PRIVACY_GRANTS")
        Resigner.identity = nil
        Resigner.cloneIdentifier = nil
        try? FileManager.default.removeItem(at: base)
    }

    private var sourceEntitlements: [String: Any] { [
        "com.apple.security.app-sandbox": true,
        "com.apple.application-identifier": "5A4RE8SF68.com.tencent.xinWeChat",
        "com.apple.security.application-groups": ["5A4RE8SF68.com.tencent.xinWeChat"],
        "com.apple.security.temporary-exception.mach-lookup.global-name": ["com.tencent.xinWeChat-spks"],
        "com.apple.security.device.camera": true,
        "com.apple.security.network.client": true,
    ] }

    /// A WeChat-shaped fixture: sandboxed root with Tencent's identity, one nested helper app that
    /// is sandboxed too, signed ad-hoc under WeChat's identifier. `_MASReceipt` marks it as an
    /// App Store install so no updater patch points are needed.
    private func makeSource(name: String = "WeChat.app", appStore: Bool = true) throws -> URL {
        let fm = FileManager.default
        let app = base.appendingPathComponent(name, isDirectory: true)
        let helper = app.appendingPathComponent("Contents/MacOS/Helper.app", isDirectory: true)
        try fm.createDirectory(at: helper.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/WeChat").path)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: helper.appendingPathComponent("Contents/MacOS/Helper").path)
        try write(["CFBundleExecutable": "WeChat", "CFBundleIdentifier": Clone.originalBundleID, "CFBundleVersion": "999999"],
                  to: app.appendingPathComponent("Contents/Info.plist"))
        try write(["CFBundleExecutable": "Helper", "CFBundleIdentifier": "com.tencent.xinWeChat.Helper"],
                  to: helper.appendingPathComponent("Contents/Info.plist"))
        if appStore {
            try fm.createDirectory(at: app.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true)
            try Data("receipt".utf8).write(to: app.appendingPathComponent("Contents/_MASReceipt/receipt"))
        }
        let ents = base.appendingPathComponent("source-entitlements.plist")
        try write(sourceEntitlements, to: ents)
        try sign(helper, identifier: "com.tencent.xinWeChat.Helper", entitlements: ents)
        try sign(app, identifier: Clone.originalBundleID, entitlements: ents)
        return app
    }

    private func write(_ dict: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
    }

    private func sign(_ url: URL, identifier: String, entitlements: URL) throws {
        let r = LocalIdentity.capture("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, "--entitlements", entitlements.path, url.path])
        XCTAssertEqual(r.status, 0, r.output)
    }

    private func entitlements(_ url: URL) throws -> [String: Any] {
        guard let data = try Resigner.inspectEntitlements(at: url) ?? nil else { return [:] }
        return (try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]) ?? [:]
    }

    private func tree(_ url: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        while let item = e?.nextObject() as? URL {
            if let d = try? Data(contentsOf: item) { out[String(item.path.dropFirst(url.path.count))] = d }
        }
        return out
    }

    func testCopyGetsItsOwnIdentityAndLeavesSourceUntouched() async throws {
        let source = try makeSource()
        let before = tree(source)
        let copy = base.appendingPathComponent("Copies/WeChat2.app", isDirectory: true)

        try await Clone.make(source: source, destination: copy, bundleID: "com.tencent.xinWeChat2", config: nil, signing: .adhoc)

        XCTAssertEqual(Clone.bundleID(of: copy), "com.tencent.xinWeChat2")
        XCTAssertEqual(Clone.signedIdentifier(of: copy), "com.tencent.xinWeChat2", "Info.plist alone is not enough: the signature must carry the new identifier")
        XCTAssertEqual(Clone.signedIdentifier(of: copy.appendingPathComponent("Contents/MacOS/Helper.app")), "com.tencent.xinWeChat.Helper",
                       "nested code keeps its own identifier")
        XCTAssertEqual(LocalIdentity.capture("/usr/bin/codesign", ["--verify", "--deep", "--strict", copy.path]).status, 0)

        for object in [copy, copy.appendingPathComponent("Contents/MacOS/Helper.app")] {
            let ents = try entitlements(object)
            XCTAssertTrue(ents.keys.filter(Clone.isIdentityBound).isEmpty, "\(object.lastPathComponent) still tied to Tencent's container: \(ents.keys.sorted())")
            XCTAssertEqual(ents["com.apple.security.device.camera"] as? Bool, true, "ordinary entitlements stay")
            XCTAssertEqual(ents["com.apple.security.cs.disable-library-validation"] as? Bool, true)
        }

        XCTAssertEqual(tree(source), before, "the source WeChat is only read")
        XCTAssertEqual(Clone.signedIdentifier(of: source), Clone.originalBundleID)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["WeChat2.app"], "no work directory left behind")
    }

    func testCopyKeepsOneIdentityAcrossRebuilds() async throws {
        let source = try makeSource()
        let copy = base.appendingPathComponent("WeChat2.app", isDirectory: true)
        try await Clone.make(source: source, destination: copy, bundleID: "com.tencent.xinWeChat2", config: nil, signing: .local)
        let first = try XCTUnwrap(Command.designatedRequirement(of: copy))
        XCTAssertTrue(first.contains("identifier \"com.tencent.xinWeChat2\""), first)

        // WeChat was updated: the copy is rebuilt from different bytes.
        try Data("new version".utf8).write(to: source.appendingPathComponent("Contents/Resources.bin"))
        try await Clone.make(source: source, destination: copy, bundleID: "com.tencent.xinWeChat2", config: nil, signing: .local)
        XCTAssertEqual(Command.designatedRequirement(of: copy), first, "privacy grants given to the copy must survive a rebuild")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appendingPathComponent("Contents/Resources.bin").path))
    }

    func testRefusesToReplaceSomethingThatIsNotThisCopy() async throws {
        let source = try makeSource()
        let other = try makeSource(name: "Other.app")   // bundle id com.tencent.xinWeChat, not the copy's
        let before = tree(other)
        do {
            try await Clone.make(source: source, destination: other, bundleID: "com.tencent.xinWeChat2", config: nil, signing: .adhoc)
            XCTFail("must refuse")
        } catch let error as Clone.Error {
            XCTAssertEqual(error, .destinationForeign(path: other.standardizedFileURL.path, bundleID: Clone.originalBundleID))
        }
        XCTAssertEqual(tree(other), before)
    }

    func testRefusesACopyWhoseUpdaterCannotBeBlocked() async throws {
        // Direct-download build that config.json does not know: an unblocked copy would be
        // replaced by the official bundle at the next update, so none is made.
        let source = try makeSource(appStore: false)
        let copy = base.appendingPathComponent("Copies/WeChat2.app", isDirectory: true)
        do {
            try await Clone.make(source: source, destination: copy, bundleID: "com.tencent.xinWeChat2", config: nil, signing: .adhoc)
            XCTFail("must refuse")
        } catch let error as Clone.Error {
            guard case .updateBlockUnavailable = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path), [], "failed run leaves nothing behind")
    }

    func testBundleIdentifierRules() {
        XCTAssertTrue(Clone.isValid(bundleID: "com.tencent.xinWeChat2"))
        XCTAssertFalse(Clone.isValid(bundleID: Clone.originalBundleID), "the copy must not share WeChat's identifier")
        XCTAssertFalse(Clone.isValid(bundleID: "WeChat2"))
        XCTAssertFalse(Clone.isValid(bundleID: "com.tencent.xin WeChat"))
        XCTAssertFalse(Clone.isValid(bundleID: "com..x"))
    }

    func testSameSourceAndDestinationIsRefused() async throws {
        let source = try makeSource()
        do {
            try await Clone.make(source: source, destination: source, bundleID: "com.tencent.xinWeChat2", config: nil, signing: .adhoc)
            XCTFail("must refuse")
        } catch let error as Clone.Error {
            XCTAssertEqual(error, .sameAsSource)
        }
    }
}

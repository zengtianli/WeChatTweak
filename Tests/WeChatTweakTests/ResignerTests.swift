import XCTest
@testable import WeChatTweak

final class ResignerTests: XCTestCase {
    private func plist(_ dict: [String: Any]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    /// The two keys that let an ad-hoc identity run WeChat's sandboxed/hardened code get
    /// added to every profile that already has entitlements — and to nothing else.
    func testInjectAddsKeysOnlyToExistingProfiles() throws {
        let original: [String: Any] = [
            "com.apple.security.app-sandbox": true,
            "com.apple.application-identifier": "5A4RE8SF68.com.tencent.xinWeChat",
        ]
        let out = try XCTUnwrap(Resigner.inject(plist(original)))
        let dict = try XCTUnwrap(PropertyListSerialization.propertyList(from: out, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(dict["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(dict["com.apple.application-identifier"] as? String, "5A4RE8SF68.com.tencent.xinWeChat")
        XCTAssertEqual(dict["com.apple.security.cs.disable-library-validation"] as? Bool, true)
        XCTAssertEqual(dict["com.apple.security.cs.allow-unsigned-executable-memory"] as? Bool, true)
        XCTAssertEqual(dict.count, 4)
        XCTAssertNil(Resigner.inject(nil), "code without entitlements must stay without")
    }

    func testInjectIsIdempotent() throws {
        let once = try XCTUnwrap(Resigner.inject(plist(["a": 1])))
        let twice = try XCTUnwrap(Resigner.inject(once))
        XCTAssertTrue(Resigner.plistsEqual(once, twice))
    }

    /// Comparison is semantic (dictionary equality), not byte equality — codesign re-serialises plists.
    func testPlistsEqualIsSemantic() {
        let a = plist(["x": true, "y": ["1", "2"]])
        let b = Data(String(decoding: plist(["y": ["1", "2"], "x": true]), as: UTF8.self).replacingOccurrences(of: "\n", with: "\n ").utf8)
        XCTAssertTrue(Resigner.plistsEqual(a, b))
        XCTAssertFalse(Resigner.plistsEqual(a, plist(["x": false, "y": ["1", "2"]])))
    }

    /// Bundle walk finds nested apps/appex/frameworks/dylibs, skips symlinks and plain data.
    func testCodeSigningCandidatesWalksNestedCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wt-cands-\(UUID().uuidString)/Fake.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let fm = FileManager.default
        for dir in ["Contents/MacOS/Helper.app", "Contents/PlugIns/Share.appex", "Contents/Frameworks/X.framework/Versions/A", "Contents/Resources"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        fm.createFile(atPath: root.appendingPathComponent("Contents/Resources/wechat.dylib").path, contents: Data([0xCF, 0xFA, 0xED, 0xFE]))
        fm.createFile(atPath: root.appendingPathComponent("Contents/Resources/data.bin").path, contents: Data([1, 2, 3]))
        fm.createFile(atPath: root.appendingPathComponent("Contents/MacOS/Fake").path, contents: Data([1]), attributes: [.posixPermissions: 0o755])
        try fm.createSymbolicLink(at: root.appendingPathComponent("Contents/Frameworks/X.framework/Versions/Current"), withDestinationURL: root.appendingPathComponent("Contents/Frameworks/X.framework/Versions/A"))

        let found = Set(Resigner.codeSigningCandidates(in: root).map { $0.standardizedFileURL.path.replacingOccurrences(of: root.standardizedFileURL.path, with: "") })
        XCTAssertTrue(found.contains(""), "root app")
        XCTAssertTrue(found.contains("/Contents/MacOS/Helper.app"))
        XCTAssertTrue(found.contains("/Contents/PlugIns/Share.appex"))
        XCTAssertTrue(found.contains("/Contents/Frameworks/X.framework"))
        XCTAssertTrue(found.contains("/Contents/Resources/wechat.dylib"))
        XCTAssertTrue(found.contains("/Contents/MacOS/Fake"), "executable file")
        XCTAssertFalse(found.contains("/Contents/Resources/data.bin"), "plain data is not code")
        XCTAssertFalse(found.contains("/Contents/Frameworks/X.framework/Versions/Current"), "symlink skipped")
    }

    /// A failed sign of a locked bundle used to leave a locked `.cstemp` that broke every retry.
    func testFailedSignOfLockedBundleLeavesNoTempAndRetrySucceeds() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("wt-cstemp-\(UUID().uuidString)", isDirectory: true)
        let app = base.appendingPathComponent("Locked.app", isDirectory: true)
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let exe = macos.appendingPathComponent("Locked")
        defer {
            if let e = fm.enumerator(atPath: base.path) {
                for case let rel as String in e { try? fm.setAttributes([.immutable: false], ofItemAtPath: base.appendingPathComponent(rel).path) }
            }
            try? fm.removeItem(at: base)
        }
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/bin/echo", toPath: exe.path)
        let info: [String: Any] = ["CFBundleExecutable": "Locked", "CFBundleIdentifier": "test.locked"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        try sign.run(); sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)

        try fm.setAttributes([.immutable: true], ofItemAtPath: exe.path)
        XCTAssertThrowsError(try Resigner.resign(app: app, patchedBinaries: []))
        try fm.setAttributes([.immutable: false], ofItemAtPath: exe.path)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: macos.path), ["Locked"], "no .cstemp left behind")

        try Resigner.resign(app: app, patchedBinaries: [])
    }

    /// 4.1.15 (270100) ships a JSON file inside a nested app's Frameworks; codesign keeps
    /// that file's signature in com.apple.cs.* xattrs. Stripping quarantine after signing
    /// must leave those alone, or the bundle reads "code object is not signed at all".
    func testQuarantineStripKeepsXattrStoredSignatures() throws {
        let fm = FileManager.default
        let app = fm.temporaryDirectory.appendingPathComponent("wechattweak-xattr-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: app) }
        let macos = app.appendingPathComponent("Contents/MacOS")
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macos.appendingPathComponent("Fixture"))
        try plist(["CFBundleExecutable": "Fixture", "CFBundleIdentifier": "test.wechattweak.xattr"])
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("{}".utf8).write(to: frameworks.appendingPathComponent("icd.json"))

        func codesign(_ args: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        XCTAssertEqual(codesign(["--force", "--deep", "--sign", "-", app.path]), 0)
        XCTAssertEqual(codesign(["--verify", "--deep", "--strict", app.path]), 0)

        Resigner.stripQuarantine(app)
        XCTAssertEqual(codesign(["--verify", "--deep", "--strict", app.path]), 0,
                       "quarantine strip destroyed the xattr-stored signature of Frameworks/icd.json")
    }
}

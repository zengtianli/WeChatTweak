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
}

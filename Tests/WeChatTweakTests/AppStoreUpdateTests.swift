import XCTest
@testable import WeChatTweak

/// Anti-revoke and the update block are independent features (issues #1 / #3): one that
/// cannot be applied is reported and skipped, never a reason to leave the other undone.
/// These drive `Command.patchFeatures` on a throwaway bundle whose wechat.dylib is an ObjC
/// fixture — with or without WeChat's updater class, with or without an App Store receipt.
final class AppStoreUpdateTests: XCTestCase {
    private func bundle(updater: Bool, appStore: Bool) throws -> (app: URL, entry: Config.Entry) {
        let fx = try ObjCFixture.write(className: updater ? UpdateLocator.className : "XAppSomethingElse",
                                       methods: ObjCFixture.pristineUpdateMethods())
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechattweak-features-\(UUID().uuidString).app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fx.url, to: app.appendingPathComponent(Command.dylibBinary))
        if appStore {
            let receipt = app.appendingPathComponent("Contents/_MASReceipt")
            try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
            try Data("receipt".utf8).write(to: receipt.appendingPathComponent("receipt"))
        }
        // A stand-in anti-revoke point inside the decoy method (not one the updater block touches).
        let va = try XCTUnwrap(fx.imps["sparkleUpdater"])
        let prologue = String(format: "%08X", ObjCFixture.stpPrologue.byteSwapped)
        let entry = try Config.Entry(arch: .arm64, addr: va, asmHex: "C0035FD6", expectedHex: [prologue])
        return (app, entry)
    }

    private func config(_ entry: Config.Entry, identifier: String = "revoke") -> Config {
        Config(version: "269602", targets: [Config.Target(identifier: identifier, entries: [entry], binary: Command.dylibBinary)])
    }

    private func revokeState(_ app: URL, _ entry: Config.Entry) throws -> Patcher.State? {
        try Patcher.inspect(binary: app.appendingPathComponent(Command.dylibBinary), entries: [entry]).first?.state
    }

    func testBothFeaturesApplyWhenBothAvailable() throws {
        let (app, entry) = try bundle(updater: true, appStore: false)
        defer { try? FileManager.default.removeItem(at: app) }
        let outcome = try Command.patchFeatures(app: app, config: config(entry))
        XCTAssertNotNil(outcome.applied[.antiRevoke])
        XCTAssertNotNil(outcome.applied[.updateBlock])
        XCTAssertEqual(try revokeState(app, entry), .patched)
    }

    func testAppStoreInstallWithoutUpdaterStillPatchesAntiRevoke() throws {
        let (app, entry) = try bundle(updater: false, appStore: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let outcome = try Command.patchFeatures(app: app, config: config(entry))
        XCTAssertEqual(outcome.touched, [Command.dylibBinary])
        XCTAssertNotNil(outcome.applied[.antiRevoke])
        XCTAssertEqual(outcome.skipped[.updateBlock], Command.appStoreUpdateNote)
        XCTAssertEqual(try revokeState(app, entry), .patched)
    }

    /// Updater missing on a direct-download build: still anti-revoke, with the reason reported.
    func testUnlocatableUpdaterDoesNotBlockAntiRevoke() throws {
        let (app, entry) = try bundle(updater: false, appStore: false)
        defer { try? FileManager.default.removeItem(at: app) }
        let outcome = try Command.patchFeatures(app: app, config: config(entry))
        XCTAssertNotNil(outcome.applied[.antiRevoke])
        XCTAssertTrue(outcome.skipped[.updateBlock]?.contains("could not be located") ?? false,
                      outcome.skipped[.updateBlock] ?? "nil")
        XCTAssertEqual(try revokeState(app, entry), .patched)
    }

    /// And the other way round: no keeptip point for this build, the update block still goes in.
    func testMissingAntiRevokeDoesNotBlockUpdateBlock() throws {
        let (app, entry) = try bundle(updater: true, appStore: false)
        defer { try? FileManager.default.removeItem(at: app) }
        let outcome = try Command.patchFeatures(app: app, config: config(entry), variant: .keeptip)
        XCTAssertNotNil(outcome.skipped[.antiRevoke])
        XCTAssertNotNil(outcome.applied[.updateBlock])
        XCTAssertEqual(try revokeState(app, entry), .pristine)
    }

    func testNothingApplicableThrows() throws {
        let (app, entry) = try bundle(updater: false, appStore: false)
        defer { try? FileManager.default.removeItem(at: app) }
        XCTAssertThrowsError(try Command.patchFeatures(app: app, config: config(entry), variant: .keeptip)) { error in
            guard case Command.Error.nothingApplied(let lines) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(lines.count, 2)
        }
    }
}

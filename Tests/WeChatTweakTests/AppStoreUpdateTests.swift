import XCTest
@testable import WeChatTweak

/// Issues #1 / #3: the Mac App Store build of 269602 has no XAppUpdateManager (the App Store
/// updates it), so the default "block auto-update" step failed and nothing got patched.
/// These drive `Command.patch` on a throwaway bundle whose wechat.dylib has an ObjC class
/// list without the updater — once with an App Store receipt, once without.
final class AppStoreUpdateTests: XCTestCase {
    private func bundle(appStore: Bool) throws -> (app: URL, entry: Config.Entry) {
        let fx = try ObjCFixture.write(className: "XAppSomethingElse", methods: ObjCFixture.pristineUpdateMethods())
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechattweak-appstore-\(UUID().uuidString).app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fx.url, to: app.appendingPathComponent(Command.dylibBinary))
        if appStore {
            let receipt = app.appendingPathComponent("Contents/_MASReceipt")
            try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
            try Data("receipt".utf8).write(to: receipt.appendingPathComponent("receipt"))
        }
        // A stand-in anti-revoke point: startUpdater's prologue word, rewritten to `ret`.
        let va = try XCTUnwrap(fx.imps["startUpdater"])
        let prologue = String(format: "%08X", ObjCFixture.stpPrologue.byteSwapped)
        let entry = try Config.Entry(arch: .arm64, addr: va, asmHex: "C0035FD6", expectedHex: [prologue])
        return (app, entry)
    }

    private func config(_ entry: Config.Entry) -> Config {
        Config(version: "269602", targets: [Config.Target(identifier: "revoke", entries: [entry], binary: Command.dylibBinary)])
    }

    func testAppStoreInstallWithoutUpdaterStillPatches() throws {
        let (app, entry) = try bundle(appStore: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let touched = try Command.patch(app: app, config: config(entry))
        XCTAssertEqual(touched, [Command.dylibBinary])
        let binary = app.appendingPathComponent(Command.dylibBinary)
        XCTAssertTrue(try Patcher.inspect(binary: binary, entries: [entry]).allSatisfy { $0.state == .patched })
    }

    /// A direct-download build without the updater must still refuse: an unblocked
    /// updater is how the patch used to vanish silently.
    func testDirectDownloadWithoutUpdaterStillRefuses() throws {
        let (app, entry) = try bundle(appStore: false)
        defer { try? FileManager.default.removeItem(at: app) }
        XCTAssertThrowsError(try Command.patch(app: app, config: config(entry))) { error in
            guard case Command.Error.updateUnavailable = error else { return XCTFail("got \(error)") }
        }
        let binary = app.appendingPathComponent(Command.dylibBinary)
        XCTAssertTrue(try Patcher.inspect(binary: binary, entries: [entry]).allSatisfy { $0.state == .pristine })
    }
}

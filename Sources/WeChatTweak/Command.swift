//
//  Command.swift
//
//  Created by Sunny Young.
//

import Foundation
import ArgumentParser

struct Command {
    enum Error: @unchecked Sendable, LocalizedError {
        case executing(command: String, error: NSDictionary)
        case keeptipUnavailable(version: String)
        case revokeUnavailable(version: String)
        case nothingApplied([String])
        case restoreUnavailable(version: String, targets: [String])

        var errorDescription: String? {
            switch self {
            case let .executing(command, error):
                return "executing: \(command) error: \(error)"
            case let .keeptipUnavailable(version):
                return """
                    config.json has no `revoke-keeptip` patch point for WeChat build \(version) yet.
                    On a matching parseRevokeXML signature, let the tool find it itself:
                        sudo wechattweak patch --variant keeptip --auto-locate
                    or curate it into config.json first:
                        python3 tools/locate_revoke.py --append && swift build -c release
                    """
            case let .restoreUnavailable(version, targets):
                return """
                    Cannot restore WeChat build \(version): config.json records no original bytes for \
                    \(targets.joined(separator: ", ")), so there is nothing to write back — and guessing \
                    would corrupt the binary. Those entries predate the `expected` field (WeChat 3.8.x only).
                    Reinstall WeChat from https://mac.weixin.qq.com to get a pristine bundle.
                    """
            case let .revokeUnavailable(version):
                return "config.json has no anti-revoke patch point for WeChat build \(version)."
            case let .nothingApplied(lines):
                return "Nothing was patched:\n" + lines.map { "  " + $0 }.joined(separator: "\n")
            }
        }
    }

    /// Revoke targets that are mutually exclusive by variant. Non-revoke targets
    /// (updaters, multi-instance) are always applied regardless of variant.
    static let silentRevokeIdentifier = "revoke"
    static let keeptipRevokeIdentifier = "revoke-keeptip"
    /// 4.x: one target with all eight update patch points (fzlzjerry's naming).
    static let updateIdentifier = "update"
    /// 3.8.x (upstream config): the same XAppUpdateManager methods, one target each, in the main binary.
    static let legacyUpdateIdentifiers: Set<String> = [
        "startUpdater", "startBackgroundUpdatesCheck", "checkForUpdates", "enableAutoUpdate",
        "automaticallyDownloadsUpdates", "canCheckForUpdate",
    ]
    static func isUpdateTarget(_ identifier: String) -> Bool {
        identifier == updateIdentifier || legacyUpdateIdentifiers.contains(identifier)
    }
    static let dylibBinary = "Contents/Resources/wechat.dylib"
    /// Mac App Store installs carry a receipt; their updates come from the App Store, and the
    /// App Store build of 269602 ships without WeChat's own updater class (issues #1, #3).
    static func isAppStoreInstall(app: URL) -> Bool {
        FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/_MASReceipt/receipt").path)
    }
    /// The in-app updater is absent *because* this is an App Store install — nothing to block.
    /// Only the exact "class not found" case qualifies: anything else (ambiguous class, changed
    /// code) still fails loudly, and a direct-download build without the class still fails too,
    /// since that is how the patch used to get silently reverted.
    static func updaterAbsentOnAppStore(app: URL, error: Swift.Error) -> Bool {
        guard isAppStoreInstall(app: app), case UpdateLocator.Error.classNotFound = error else { return false }
        return true
    }
    static func updateUnavailableNote(_ reason: String) -> String {
        "this build's updater could not be located (\(reason)); anti-revoke works without it, but a WeChat update will remove the patch — run patch again afterwards"
    }
    static let appStoreUpdateNote = "App Store install: this build has no in-app updater (the App Store updates it), so there is nothing to block. Turn off App Store automatic updates to keep the patch."
    /// A 4.x config entry patches wechat.dylib; 3.8.x entries patch the main executable.
    static func isWeChat4(_ config: Config) -> Bool {
        config.targets.contains { $0.binary == dylibBinary }
    }

    /// The code WeChat actually executes on this Mac. A universal wechat.dylib carries both
    /// slices, and config.json may know only one of them — patching the arm64 slice on an
    /// Intel Mac changes nothing the user will ever run (WeChatTweak issue #7).
    /// `WECHATTWEAK_HOST_ARCH=x86_64|arm64` overrides the probe: for WeChat forced to run
    /// under Rosetta, and for exercising the Intel path on Apple silicon.
    static var hostArch: Config.Arch {
        if let forced = ProcessInfo.processInfo.environment["WECHATTWEAK_HOST_ARCH"],
           let arch = Config.Arch(rawValue: forced) {
            return arch
        }
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // Reports the hardware even when this process is translated by Rosetta.
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 { return .arm64 }
        return .x86_64
    }
    static func supports(_ arch: Config.Arch, _ targets: [Config.Target]) -> Bool {
        targets.contains { $0.entries.contains { $0.arch == arch } }
    }
    static func archUnsupportedNote(build: String, arch: Config.Arch, feature: String) -> String {
        "no \(arch.rawValue) patch points for \(feature) in build \(build) — this Mac runs WeChat's \(arch.rawValue) code, and the patch points on record are for the other architecture, so writing them would change nothing here"
    }

    /// Version strings as WeChat's own Info.plist states them. `CFBundleVersion` (the build
    /// number config.json is keyed by) says nothing a user recognises; `WeChatBundleVersion`
    /// is the four-part version shown in WeChat's About window (4.x only).
    static func bundleVersions(app: URL) -> (full: String?, short: String?) {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return (info?["WeChatBundleVersion"] as? String, info?["CFBundleShortVersionString"] as? String)
    }
    /// `appStore` when the bundle carries a Mac App Store receipt, otherwise `direct`
    /// (the download from mac.weixin.qq.com, Homebrew included).
    static func installChannel(app: URL) -> String {
        isAppStoreInstall(app: app) ? "appStore" : "direct"
    }

    static func version(app: URL) async throws -> String? {
        try await Command.execute(command: "defaults read \(q(app.appendingPathComponent("Contents/Info.plist").path)) CFBundleVersion")
    }

    /// Shell-quote a path for the `do shell script` command line. Upstream interpolated
    /// paths bare, so any `-a` path containing a space (e.g. a copy on an external
    /// volume) split into two arguments.
    static func q(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let defaultBinary = "Contents/MacOS/WeChat"

    /// True if any process is running out of this bundle's `Contents/MacOS/`.
    static func isRunning(app: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", app.standardizedFileURL.appendingPathComponent("Contents/MacOS/").path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// What one `patch` run did, feature by feature. Anti-revoke and the update block are
    /// independent: one that cannot be applied is reported and skipped, never a reason to
    /// leave the other undone.
    struct PatchOutcome {
        enum Feature: String, CaseIterable {
            case antiRevoke = "Anti-revoke"
            case updateBlock = "Update block"
        }
        var applied: [Feature: String] = [:]
        var skipped: [Feature: String] = [:]
        /// Bundle-relative binaries that were written, so `resign` can sign them first.
        var touched: [String] = []
        /// Why macOS refused a write, when one was refused (see `WriteAccess`). One diagnosis
        /// per run: both features write the same bundle.
        var writeBlocked: [String] = []

        var summary: [String] {
            Feature.allCases.compactMap { f in
                if let detail = applied[f] { return "\(f.rawValue): applied (\(detail))" }
                if let why = skipped[f] { return "\(f.rawValue): NOT applied — \(why)" }
                return nil
            } + writeBlocked
        }
    }

    /// Patches every target into its own binary (default `Contents/MacOS/WeChat`;
    /// WeChat 4.x targets `Contents/Resources/wechat.dylib`). Returns the unique
    /// bundle-relative paths that were touched, so `resign` can sign them first.
    /// Throws only when nothing at all could be applied.
    @discardableResult
    static func patch(app: URL, config: Config, variant: PatchVariant = .silent, autoLocate: Bool = false, blockUpdate: Bool = true, hostArch: Config.Arch = Command.hostArch) throws -> [String] {
        try patchFeatures(app: app, config: config, variant: variant, autoLocate: autoLocate, blockUpdate: blockUpdate, hostArch: hostArch).touched
    }

    static func patchFeatures(app: URL, config: Config, variant: PatchVariant = .silent, autoLocate: Bool = false, blockUpdate: Bool = true, hostArch: Config.Arch = Command.hostArch) throws -> PatchOutcome {
        var outcome = PatchOutcome()

        // ── Anti-revoke (plus build extras such as multiInstance) ──
        // The two revoke targets are mutually exclusive: pick the one matching the variant.
        var revokeTargets = config.targets.filter { t in
            guard !Command.isUpdateTarget(t.identifier) else { return false }
            switch t.identifier {
            case Command.silentRevokeIdentifier: return variant == .silent
            case Command.keeptipRevokeIdentifier: return variant == .keeptip
            default: return true
            }
        }
        let wantedRevoke = variant == .keeptip ? Command.keeptipRevokeIdentifier : Command.silentRevokeIdentifier
        if !revokeTargets.contains(where: { $0.identifier == wantedRevoke }) {
            // keeptip needs a `revoke-keeptip` target: derive it (--auto-locate) or report it —
            // never claim anti-revoke without touching a byte.
            do {
                guard variant == .keeptip else { throw Error.revokeUnavailable(version: config.version) }
                guard autoLocate else { throw Error.keeptipUnavailable(version: config.version) }
                revokeTargets.append(try autoLocatedKeeptipTarget(app: app, config: config))
            } catch {
                outcome.skipped[.antiRevoke] = error.localizedDescription
                revokeTargets.removeAll { $0.identifier == Command.silentRevokeIdentifier || $0.identifier == Command.keeptipRevokeIdentifier }
            }
        }

        // ── Update block ──
        // A 4.x build not yet curated with an `update` target is located live by walking the ObjC
        // metadata (by name, then instruction-shape and expected-byte checks).
        var updateTargets: [Config.Target] = []
        if !blockUpdate {
            outcome.skipped[.updateBlock] = "turned off with --no-block-update; a WeChat update will remove the patch"
        } else if case let curated = config.targets.filter({ Command.isUpdateTarget($0.identifier) }), !curated.isEmpty {
            updateTargets = curated
        } else if Command.isWeChat4(config) {
            do {
                updateTargets = [try autoLocatedUpdateTarget(app: app)]
            } catch where Command.updaterAbsentOnAppStore(app: app, error: error) {
                outcome.skipped[.updateBlock] = Command.appStoreUpdateNote
            } catch {
                outcome.skipped[.updateBlock] = Command.updateUnavailableNote(error.localizedDescription)
            }
        } else {
            outcome.skipped[.updateBlock] = "config.json has no updater patch points for this 3.x build"
        }

        // Each feature is written on its own, so a failure in one leaves the other intact.
        // Within a feature, entries are coalesced by image (269602's revoke and multi-instance
        // share wechat.dylib and are validated together before either is written).
        func apply(_ feature: PatchOutcome.Feature, _ targets: [Config.Target], detail: String) {
            guard !targets.isEmpty else { return }
            // Never report a feature as applied when only the other architecture's slice
            // would be written: on this Mac WeChat would run exactly as before.
            guard Command.supports(hostArch, targets) else {
                outcome.skipped[feature] = Command.archUnsupportedNote(build: config.version, arch: hostArch, feature: feature.rawValue.lowercased())
                return
            }
            var entriesByBinary: [String: [Config.Entry]] = [:]
            var order: [String] = []
            for target in targets {
                let relative = target.binary ?? Command.defaultBinary
                print("------ Target: \(target.identifier) (\(relative)) ------")
                if entriesByBinary[relative] == nil { order.append(relative) }
                entriesByBinary[relative, default: []].append(contentsOf: target.entries)
            }
            do {
                for relative in order {
                    try Patcher.patch(binary: app.appendingPathComponent(relative),
                                      entries: entriesByBinary[relative]!,
                                      backupVersion: config.version)
                    if !outcome.touched.contains(relative) { outcome.touched.append(relative) }
                }
                outcome.applied[feature] = detail
            } catch {
                outcome.skipped[feature] = error.localizedDescription
                if outcome.writeBlocked.isEmpty {
                    outcome.writeBlocked = WriteAccess.summaryLines(error, app: app)
                }
            }
        }
        apply(.antiRevoke, revokeTargets,
              detail: revokeTargets.map(\.identifier).joined(separator: ", "))
        apply(.updateBlock, updateTargets, detail: "\(updateTargets.flatMap(\.entries).count) patch points")

        print("------ Summary ------")
        outcome.summary.forEach { print($0) }
        guard !outcome.applied.isEmpty else { throw Error.nothingApplied(outcome.summary) }
        return outcome
    }

    /// Undo everything `patch` writes: put every patch point back to its pristine bytes.
    ///
    /// Convention (verified across all 37 builds in config.json): `expected[0]` is the
    /// pristine value; any further entries are accepted-but-not-pristine variants — e.g.
    /// keeptip tolerates the silent patch already being there. So the inverse of an entry
    /// is "write expected[0], accepting either the patched bytes or the pristine ones".
    /// That makes restore idempotent, and it still refuses on foreign bytes because
    /// `Patcher` gates every write on the expected list.
    ///
    /// Fails loudly — never partially — when a target carries no `expected` at all: those
    /// five WeChat 3.8.x builds predate the bookkeeping, so there is no original to write
    /// back and a guess would corrupt someone's WeChat.
    @discardableResult
    static func restore(app: URL, config: Config) throws -> [String] {
        let missing = config.targets
            .filter { $0.entries.contains { $0.expected.isEmpty } }
            .map(\.identifier)
        guard missing.isEmpty else {
            throw Error.restoreUnavailable(version: config.version, targets: missing)
        }

        var entriesByBinary: [String: [Config.Entry]] = [:]
        var binaryOrder: [String] = []
        for target in config.targets {
            let relative = target.binary ?? Command.defaultBinary
            let inverted = try target.entries.map { entry -> Config.Entry in
                let pristine = entry.expected[0]
                // Accept the patched bytes *and* every already-accepted original, so running
                // restore twice is a no-op rather than an "unexpected bytes" failure.
                var accept = [entry.asm.hexString]
                accept.append(contentsOf: entry.expected.map(\.hexString))
                var seen = Set<String>()
                let unique = accept.filter { seen.insert($0).inserted }
                return try Config.Entry(arch: entry.arch, addr: entry.addr, asmHex: pristine.hexString, expectedHex: unique)
            }
            print("------ Restore: \(target.identifier) (\(relative)) ------")
            if entriesByBinary[relative] == nil {
                binaryOrder.append(relative)
            }
            var combined = entriesByBinary[relative, default: []]
            for entry in inverted {
                // `revoke` and `revoke-keeptip` deliberately restore their
                // shared selector to the same pristine bytes. Merge that one
                // range so Patcher can still reject genuinely overlapping
                // writes while restoring either variant in one transaction.
                if let index = combined.firstIndex(where: {
                    $0.arch.rawValue == entry.arch.rawValue && $0.addr == entry.addr && $0.asm == entry.asm
                }) {
                    var seen = Set<String>()
                    let expected = (combined[index].expected + entry.expected)
                        .map(\.hexString)
                        .filter { seen.insert($0).inserted }
                    combined[index] = try Config.Entry(arch: entry.arch,
                                                       addr: entry.addr,
                                                       asmHex: entry.asm.hexString,
                                                       expectedHex: expected)
                } else {
                    combined.append(entry)
                }
            }
            entriesByBinary[relative] = combined
        }

        var patched: [String] = []
        for relative in binaryOrder {
            // Restoring uses expected originals already captured in config.json;
            // it must not create a new backup of the patched image.
            try Patcher.patch(binary: app.appendingPathComponent(relative), entries: entriesByBinary[relative]!)
            patched.append(relative)
        }
        return patched
    }

    /// Derives a `revoke-keeptip` target by scanning the binary for the revoke code
    /// signature. Used only with `--auto-locate`; the derived addresses still go
    /// through `Patcher`'s expected-byte check before anything is written.
    private static func autoLocatedKeeptipTarget(app: URL, config: Config) throws -> Config.Target {
        // Patch the same binary the build's silent revoke target uses (4.x: wechat.dylib).
        let relative = config.targets
            .first { $0.identifier == Command.silentRevokeIdentifier }?
            .binary ?? Command.defaultBinary
        let binary = app.appendingPathComponent(relative)
        let hit = try RevokeLocator.locate(binary: binary)
        print("------ Auto-locate ------")
        print(String(format: "[arm64] signature hit (%@) — silent VA=0x%llx, keeptip VA=0x%llx (+0x%llx)",
                     hit.signature.name, hit.silentVA, hit.keeptipVA, hit.signature.delta))
        if let curated = config.targets.first(where: { $0.identifier == Command.silentRevokeIdentifier })?.entries.first,
           curated.addr != hit.silentVA {
            print(String(format: "[arm64] warning: config.json lists silent VA=0x%llx but the signature hit 0x%llx",
                         curated.addr, hit.silentVA))
        }
        return Config.Target(identifier: Command.keeptipRevokeIdentifier,
                             entries: try RevokeLocator.keeptipEntries(from: hit),
                             binary: relative)
    }

    /// Derives the `update` target by walking wechat.dylib's ObjC metadata (see `UpdateLocator`).
    private static func autoLocatedUpdateTarget(app: URL) throws -> Config.Target {
        let binary = app.appendingPathComponent(Command.dylibBinary)
        let hits = try UpdateLocator.locate(binary: binary)
        print("------ Auto-locate (update) ------")
        for hit in hits {
            print(String(format: "[arm64] %@ VA=0x%llx%@", hit.method, hit.va, hit.alreadyPatched ? " (already patched)" : ""))
        }
        return Config.Target(identifier: Command.updateIdentifier, entries: hits.map(\.entry), binary: Command.dylibBinary)
    }

    /// Re-sign after patching. See `Resigner.swift` for why this is more than
    /// `codesign --deep --sign -` (App Sandbox + Hardened Runtime + Team-ID entitlements).
    static func resign(app: URL, patchedBinaries: [String] = []) async throws {
        let nested = patchedBinaries
            .filter { $0 != Command.defaultBinary }
            .map { app.appendingPathComponent($0) }
        try Resigner.resign(app: app, patchedBinaries: nested)
    }

    @discardableResult
    private static func execute(command: String) async throws -> String? {
        // The command is embedded in an AppleScript string literal: escape backslashes
        // and double quotes so the shell single-quoting above survives intact.
        let literal = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(source: "do shell script \"\(literal)\"") else {
            throw Error.executing(
                command: command,
                error: ["error": "Create script failed."]
            )
        }

        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)

        if let error = error {
            throw Error.executing(
                command: command,
                error: error
            )
        } else {
            return descriptor.stringValue
        }
    }
}

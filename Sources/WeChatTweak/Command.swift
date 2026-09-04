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
        case updateUnavailable(version: String, reason: String)
        case restoreUnavailable(version: String, targets: [String])

        var errorDescription: String? {
            switch self {
            case let .executing(command, error):
                return "executing: \(command) error: \(error)"
            case let .keeptipUnavailable(version):
                return """
                    config.json has no `revoke-keeptip` patch point for WeChat build \(version) yet \
                    (this is missing data, not an unsupported build — the keeptip point is derivable \
                    from the silent one by its generation's fixed delta).
                    Either let the tool find it itself:
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
            case let .updateUnavailable(version, reason):
                return """
                    Cannot block WeChat's auto-updater for build \(version): \(reason)
                    Without the block, WeChat's next update silently reverts the patch (it has, four times).
                    Either curate the patch point:  python3 tools/locate_update.py --append && swift build -c release
                    or, knowingly, keep updates on:  wechattweak patch --no-block-update
                    """
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
    /// A 4.x config entry patches wechat.dylib; 3.8.x entries patch the main executable.
    static func isWeChat4(_ config: Config) -> Bool {
        config.targets.contains { $0.binary == dylibBinary }
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

    /// Patches every target into its own binary (default `Contents/MacOS/WeChat`;
    /// WeChat 4.x targets `Contents/Resources/wechat.dylib`). Returns the unique
    /// bundle-relative paths that were touched, so `resign` can sign them first.
    @discardableResult
    static func patch(app: URL, config: Config, variant: PatchVariant = .silent, autoLocate: Bool = false, blockUpdate: Bool = true) throws -> [String] {
        // keeptip needs a `revoke-keeptip` target. If this build has none, either derive
        // it from the code signature (--auto-locate) or fail loudly — never silently
        // skip the revoke target and report success without touching a byte.
        var targets = config.targets
        let hasKeeptip = targets.contains { $0.identifier == Command.keeptipRevokeIdentifier }
        if variant == .keeptip && !hasKeeptip {
            guard autoLocate else { throw Error.keeptipUnavailable(version: config.version) }
            targets.append(try autoLocatedKeeptipTarget(app: app, config: config))
        }

        // Block auto-update (default). A 4.x build not yet curated with an `update` target is
        // located live by walking the ObjC metadata — that lookup is by name and is followed by an
        // instruction-shape check plus Patcher's expected-byte gate, so it needs no opt-in flag.
        // Failing to find it is an error, not a silent skip: an unblocked updater is precisely
        // how every previous "the patch stopped working" report happened.
        let hasUpdate = targets.contains { Command.isUpdateTarget($0.identifier) }
        if blockUpdate && !hasUpdate {
            if Command.isWeChat4(config) {
                do {
                    targets.append(try autoLocatedUpdateTarget(app: app))
                } catch {
                    throw Error.updateUnavailable(version: config.version, reason: error.localizedDescription)
                }
            } else {
                print("------ Update block ------")
                print("config.json has no updater targets for this 3.x build — nothing to block; continuing.")
            }
        }

        var patched: [String] = []
        for target in targets {
            if !blockUpdate && Command.isUpdateTarget(target.identifier) {
                print("------ Target: \(target.identifier) skipped (--no-block-update) ------")
                continue
            }
            // The two revoke targets are mutually exclusive: pick the one matching the variant,
            // skip the other. Everything else (updaters, multi-instance) is applied unconditionally.
            switch target.identifier {
            case Command.silentRevokeIdentifier where variant == .keeptip:
                continue
            case Command.keeptipRevokeIdentifier where variant == .silent:
                continue
            default:
                break
            }

            let relative = target.binary ?? Command.defaultBinary
            print("------ Target: \(target.identifier) (\(relative)) ------")
            try Patcher.patch(binary: app.appendingPathComponent(relative), entries: target.entries)
            if !patched.contains(relative) {
                patched.append(relative)
            }
        }
        return patched
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

        var patched: [String] = []
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
            try Patcher.patch(binary: app.appendingPathComponent(relative), entries: inverted)
            if !patched.contains(relative) {
                patched.append(relative)
            }
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

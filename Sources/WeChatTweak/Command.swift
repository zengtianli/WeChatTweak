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
            }
        }
    }

    /// Revoke targets that are mutually exclusive by variant. Non-revoke targets
    /// (updaters, multi-instance) are always applied regardless of variant.
    static let silentRevokeIdentifier = "revoke"
    static let keeptipRevokeIdentifier = "revoke-keeptip"

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
    static func patch(app: URL, config: Config, variant: PatchVariant = .silent, autoLocate: Bool = false) throws -> [String] {
        // keeptip needs a `revoke-keeptip` target. If this build has none, either derive
        // it from the code signature (--auto-locate) or fail loudly — never silently
        // skip the revoke target and report success without touching a byte.
        var targets = config.targets
        let hasKeeptip = targets.contains { $0.identifier == Command.keeptipRevokeIdentifier }
        if variant == .keeptip && !hasKeeptip {
            guard autoLocate else { throw Error.keeptipUnavailable(version: config.version) }
            targets.append(try autoLocatedKeeptipTarget(app: app, config: config))
        }

        var patched: [String] = []
        for target in targets {
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

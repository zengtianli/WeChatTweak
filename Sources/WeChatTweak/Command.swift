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
                    from the silent one, at +0x794).
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
        try await Command.execute(command: "defaults read \(app.appendingPathComponent("Contents/Info.plist").path) CFBundleVersion")
    }

    static let defaultBinary = "Contents/MacOS/WeChat"

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
        print(String(format: "[arm64] signature hit — silent VA=0x%llx, keeptip VA=0x%llx (+0x%llx)",
                     hit.silentVA, hit.keeptipVA, RevokeLocator.delta))
        if let curated = config.targets.first(where: { $0.identifier == Command.silentRevokeIdentifier })?.entries.first,
           curated.addr != hit.silentVA {
            print(String(format: "[arm64] warning: config.json lists silent VA=0x%llx but the signature hit 0x%llx",
                         curated.addr, hit.silentVA))
        }
        return Config.Target(identifier: Command.keeptipRevokeIdentifier,
                             entries: try RevokeLocator.keeptipEntries(from: hit),
                             binary: relative)
    }

    static func resign(app: URL, patchedBinaries: [String] = []) async throws {
        // Sign each patched nested binary first, so a modified dylib already carries
        // a valid ad-hoc signature before the app-level --deep re-sign wraps it.
        // Otherwise the running app can hit `Code Signature Invalid` on the patched page.
        for relative in patchedBinaries where relative != Command.defaultBinary {
            let path = app.appendingPathComponent(relative).path
            try await Command.execute(command: "codesign --force --sign - \(path)")
        }
        try await Command.execute(command: "codesign --remove-sign \(app.path)")
        try await Command.execute(command: "codesign --force --deep --sign - \(app.path)")
        try await Command.execute(command: "xattr -cr \(app.path)")
    }

    @discardableResult
    private static func execute(command: String) async throws -> String? {
        guard let script = NSAppleScript(source: "do shell script \"\(command)\"") else {
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

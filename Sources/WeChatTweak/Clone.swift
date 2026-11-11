//
//  Clone.swift
//  WeChatTweak
//
//  A second WeChat that runs next to the first one (WeChatTweak #11, "一键多开").
//
//  WeChat 4.x allows one running instance per bundle identifier, and keys its data directory
//  (`~/Library/Containers/<bundle id>/`) by it as well. A copy of the bundle with a different
//  identifier is therefore a separate WeChat with its own login and its own chat history — no
//  per-build patch point needed. Three things make such a copy actually survive, each learned
//  the hard way on a hand-made copy:
//
//    1. The copy's built-in updater must be blocked in the binary. Otherwise the next update
//       replaces the copy with the official bundle, the identifier is `com.tencent.xinWeChat`
//       again, it fights the first WeChat for the single-instance lock and quits one second
//       after launch, silently. Sparkle preferences are not enough (the copy reads them from a
//       different place than where they were written).
//    2. The signature's identifier must be the new one, not just Info.plist's.
//    3. The copy must not keep the entitlements that tie it to Tencent's identity — the App
//       Sandbox with the `5A4RE8SF68.com.tencent.xinWeChat` application group. With them, the
//       copy shares the first WeChat's group container and WeChatAppEx dies (SIGTRAP) when both
//       are open.
//
//  The copy is built beside its destination and renamed into place only when every step
//  succeeded, so a failed run never leaves a half-made WeChat behind and never damages an
//  existing copy. The source bundle is only read.
//

import Foundation

struct Clone {
    static let originalBundleID = "com.tencent.xinWeChat"

    enum Error: LocalizedError, Equatable {
        case sameAsSource
        case invalidBundleID(String)
        case destinationRunning(String)
        case destinationForeign(path: String, bundleID: String)
        case updateBlockUnavailable(String)
        case identifierNotApplied(wanted: String, got: String)
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .sameAsSource:
                return "The copy needs its own path: --to must differ from the source WeChat."
            case let .invalidBundleID(id):
                return "\"\(id)\" cannot be used as the copy's bundle identifier. Use letters, digits, '-' and '.', e.g. \(Clone.originalBundleID)2 — and not WeChat's own \(Clone.originalBundleID)."
            case let .destinationRunning(path):
                return "The second WeChat at \(path) is still running — quit it completely first (⌘Q, wait ~10 s), then try again."
            case let .destinationForeign(path, bundleID):
                return "\(path) already exists and is not this copy (its bundle identifier is \(bundleID.isEmpty ? "unreadable" : bundleID)). Refusing to replace it; move it away or choose another --to."
            case let .updateBlockUnavailable(why):
                return """
                    Cannot make a copy that would last: this WeChat build's built-in updater could not be blocked \
                    (\(why)). An unblocked copy is replaced by the official bundle at the next update and then \
                    quits right after launch. Nothing was created.
                    """
            case let .identifierNotApplied(wanted, got):
                return "Re-signing did not give the copy its own identity (wanted \(wanted), signature says \(got.isEmpty ? "nothing" : got)). Nothing was created."
            case let .copyFailed(output):
                return "Copying WeChat failed:\n\(output)"
            }
        }
    }

    /// Entitlements that bind a bundle to Tencent's identity or to WeChat's own sandbox container.
    /// A copy must not carry them (see file header, 3). Everything else — camera, microphone,
    /// network, user-selected files, JIT — stays.
    static func isIdentityBound(_ key: String) -> Bool {
        key == "com.apple.security.app-sandbox"
            || key == "com.apple.application-identifier"
            || key == "com.apple.security.application-groups"
            || key == "keychain-access-groups"
            || key.hasPrefix("com.apple.security.temporary-exception.")
    }

    /// `~/Applications/WeChat2.app` of the person at the keyboard (also under sudo).
    static func defaultDestination() -> URL {
        let home = LocalIdentity.realUser()?.home ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Applications/WeChat2.app", isDirectory: true)
    }

    static func isValid(bundleID: String) -> Bool {
        guard bundleID != originalBundleID, !bundleID.hasPrefix("."), !bundleID.hasSuffix("."), bundleID.contains(".") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        return bundleID.unicodeScalars.allSatisfy(allowed.contains) && !bundleID.contains("..")
    }

    static func bundleID(of app: URL) -> String {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String) ?? ""
    }

    /// `Identifier=` of the bundle's signature, "" when unsigned or unreadable.
    static func signedIdentifier(of app: URL) -> String {
        let out = LocalIdentity.capture("/usr/bin/codesign", ["-dv", app.path]).output
        return out.split(separator: "\n").first { $0.hasPrefix("Identifier=") }.map { String($0.dropFirst("Identifier=".count)) } ?? ""
    }

    /// Build (or rebuild) the copy. `config` is the patch config for the source's build, nil when
    /// the build is not in config.json.
    static func make(source: URL, destination: URL, bundleID: String, config: Config?, signing: SigningMode) async throws {
        let fm = FileManager.default
        let source = source.standardizedFileURL, destination = destination.standardizedFileURL
        guard source.path != destination.path else { throw Error.sameAsSource }
        guard isValid(bundleID: bundleID) else { throw Error.invalidBundleID(bundleID) }
        if fm.fileExists(atPath: destination.path) {
            let existing = Clone.bundleID(of: destination)
            guard existing == bundleID else { throw Error.destinationForeign(path: destination.path, bundleID: existing) }
            guard !Command.isRunning(app: destination) else { throw Error.destinationRunning(destination.path) }
        }

        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Named *.app so every tool treats it as a bundle; hidden so it never shows in Launchpad.
        let work = parent.appendingPathComponent(".wechattweak-copy-\(UUID().uuidString.prefix(8)).app", isDirectory: true)
        var finished = false
        defer { if !finished { try? fm.removeItem(at: work) } }

        print("------ Copy ------")
        // -c: APFS clone, so the copy takes no extra disk space until its files diverge; cp falls
        // back to a plain copy on other volumes. No -p: the copy belongs to whoever runs this, so
        // it stays writable without sudo even when the source is a root-owned App Store install.
        let copied = LocalIdentity.capture("/bin/cp", ["-Rc", source.path, work.path])
        guard copied.status == 0 else { throw Error.copyFailed(copied.output) }
        if getuid() == 0, let user = LocalIdentity.realUser() {
            _ = LocalIdentity.capture("/usr/sbin/chown", ["-R", "\(user.uid):\(user.gid)", work.path])
        }
        Resigner.removeSigningLeftovers(in: work)
        print("Copied \(source.path)")

        print("------ Update block ------")
        let touched = try blockUpdater(in: work, config: config)

        print("------ Identity ------")
        let infoURL = work.appendingPathComponent("Contents/Info.plist")
        guard let info = NSMutableDictionary(contentsOf: infoURL) else { throw Tweak.Error.invalidApp }
        info["CFBundleIdentifier"] = bundleID
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: infoURL, options: .atomic)
        print("Bundle identifier: \(bundleID)")

        print("------ Resign ------")
        // The work copy starts out with the source's signature, so "did the identity change" is
        // judged against the copy being replaced, not inside resign: a rebuild under the same
        // identity keeps the copy's privacy grants.
        try await Command.resign(app: work, patchedBinaries: touched, signing: signing, cloneIdentifier: bundleID, resetGrants: false)
        let signed = signedIdentifier(of: work)
        guard signed == bundleID else { throw Error.identifierNotApplied(wanted: bundleID, got: signed) }
        let previous = fm.fileExists(atPath: destination.path) ? Command.designatedRequirement(of: destination) : nil
        let identityChanged = previous != Command.designatedRequirement(of: work)

        // Swap in: the old copy goes only after the new one is complete — to the Trash when
        // possible, so the version that was working can still be put back.
        if fm.fileExists(atPath: destination.path) {
            guard !Command.isRunning(app: destination) else { throw Error.destinationRunning(destination.path) }
            if getuid() == 0 || (try? fm.trashItem(at: destination, resultingItemURL: nil)) == nil {
                try fm.removeItem(at: destination)
            } else {
                print("Previous copy moved to the Trash.")
            }
        }
        try fm.moveItem(at: work, to: destination)
        finished = true
        if identityChanged { Command.resetPrivacyGrants(app: destination) }
        print("------ Done ------")
        print("Second WeChat: \(destination.path)")
        print("It has its own login and chat history (~/Library/Containers/\(bundleID)/); the first WeChat is untouched.")
    }

    /// Make sure the copy's updater is blocked; returns the bundle-relative binaries written.
    /// An App Store install has no built-in updater (the App Store updates only the original in
    /// /Applications), so there is nothing to block.
    static func blockUpdater(in app: URL, config: Config?) throws -> [String] {
        if Command.isAppStoreInstall(app: app) {
            print("App Store build: no built-in updater in the bundle, nothing to block.")
            return []
        }
        guard let config else {
            throw Error.updateBlockUnavailable("build \(Command.buildNumber(app: app) ?? "unknown") is not in config.json yet")
        }
        let outcome: Command.PatchOutcome
        do {
            outcome = try Command.patchFeatures(app: app, config: config, antiRevoke: false, blockUpdate: true)
        } catch {
            throw Error.updateBlockUnavailable(error.localizedDescription)
        }
        guard outcome.applied[.updateBlock] != nil else {
            throw Error.updateBlockUnavailable(outcome.skipped[.updateBlock] ?? "no reason given")
        }
        return outcome.touched
    }
}

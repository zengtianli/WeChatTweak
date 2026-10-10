//
//  Doctor.swift
//  WeChatTweak
//
//  `wechattweak doctor` — one read-only pass that answers, for *this* machine:
//    · which WeChat build is installed and whether config.json knows it
//    · SIP on/off, because the two behave differently when a bundle's signature is wrong
//      (SIP on: AMFI kills a bundle whose entitlements were stripped; SIP off: it runs, which
//      is exactly why a "works on my Mac" from an SIP-off machine proves nothing)
//    · whether the bundle still carries its entitlements (an old resign flow stripped them)
//    · whether sudo is needed (4.1.13+ bundles are user-owned)
//    · patch state of every relevant target: anti-revoke (silent / keeptip) and update block
//  and then says the exact next command. Nothing here writes.
//
//  Two renderings of the *same* pass (2026-09-04): `Status` is the machine-readable one
//  (`doctor --json`, consumed by the Unrevoke GUI) and `Report.text` is the human one.
//  The verdict logic lives once, in `Status.overall` — the GUI must never re-derive
//  "is it protected?" from the text, or the two answers drift the day this file changes.
//

import Foundation

struct Doctor {
    enum SIP: String, Encodable { case enabled, disabled, unknown }

    /// Machine-readable result of one doctor pass. Field names are snake_case on the wire
    /// (see `encode`), because the GUI decodes with `.convertFromSnakeCase`.
    struct Status: Encodable {
        /// The single verdict the GUI renders as its big status card. Ordered by severity:
        /// the first matching condition wins, so a broken bundle outranks a missing patch.
        enum Overall: String, Encodable {
            /// Bundle lost its entitlements — WeChat will not launch (SIP on). Reinstall.
            case brokenBundle
            /// Some patch point holds bytes that are neither pristine nor ours.
            case mixed
            /// config.json has no entry for this build yet.
            case unsupportedBuild
            /// Anti-revoke and the update block are both applied.
            case protected
            /// Anti-revoke is applied; this build's updater cannot be blocked (App Store install,
            /// or not located). Nothing more to do now — the reason is in `updateSource`.
            case antiRevokeOnly
            /// One of the two is applied, the other is not.
            case partial
            /// Nothing applied, and nothing is in the way.
            case unprotected
        }

        var overall: Overall
        var build: String?
        /// `WeChatBundleVersion`, e.g. "4.1.15.54" — the version WeChat's About window shows. nil on 3.x.
        var fullVersion: String?
        /// `CFBundleShortVersionString`, e.g. "4.1.15".
        var shortVersion: String?
        /// `appStore` (bundle has a Mac App Store receipt) or `direct`.
        var installChannel: String
        /// The architecture WeChat runs as on this Mac; patch state below is judged on that slice.
        var hostArch: String
        /// false → config.json knows this build, but has no anti-revoke patch points for `hostArch`.
        var archSupported: Bool
        var appPath: String
        var configKnown: Bool
        var configTargets: [String]
        var sip: SIP
        var running: Bool
        /// false → the patch must run with sudo.
        var writable: Bool
        /// What the filesystem itself puts in the way of a write (`WriteAccess.Blocker` raw values:
        /// needsAdmin / immutable / aclDeny / readOnlyVolume). Empty when nothing does. App Management
        /// (TCC) cannot be read without attempting a write, so it only ever appears in `patch` output.
        var writeBlockers: [String]
        var writeAccess: [WriteAccess.Item]
        var signature: String
        var entitlementsOK: Bool
        var entitlementKeyCount: Int
        /// `patched` / `pristine` / `unknown` / nil when the build has no such target.
        var antiRevokeSilent: String?
        var antiRevokeKeeptip: String?
        /// Also `notApplicable` (App Store install / 3.x build without updater patch points) and
        /// `unavailable` (the updater could not be located); the reason is in `updateSource`.
        var updateBlock: String?
        var updateSource: String
        var sparkle: [String: String]
        var verdict: [String]
        /// The exact shell command this machine should run next, or nil when there is nothing to do.
        var nextCommand: String?

        /// Which variant is currently live, if any — `silent` / `keeptip` / nil.
        var activeVariant: String? {
            if antiRevokeSilent == Patcher.State.patched.rawValue { return "silent" }
            if antiRevokeKeeptip == Patcher.State.patched.rawValue { return "keeptip" }
            return nil
        }
    }

    struct Report {
        var status: Status
        var lines: [String] = []
        var text: String {
            (["------ Doctor ------"] + lines + ["------ Verdict ------"] + status.verdict).joined(separator: "\n")
        }
        /// Pretty JSON for `--json`. snake_case keys, stable field order via the encoder.
        func json() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return String(decoding: try encoder.encode(status), as: UTF8.self)
        }
    }

    static func run(app: URL, configs: [Config], hostArch: Config.Arch = Command.hostArch) async throws -> Report {
        let fm = FileManager.default
        var lines: [String] = []

        // 1. build + config
        let version = try await Command.version(app: app)
        let config = configs.first { $0.version == version }
        let versions = Command.bundleVersions(app: app)
        let channel = Command.installChannel(app: app)
        lines.append("WeChat build: \(version ?? "unknown")  (\(app.path))")
        lines.append("Version:      \(versions.full ?? versions.short ?? "unknown")  channel=\(channel)  arch=\(hostArch.rawValue)")
        lines.append("config.json:  \(config == nil ? "NO entry for this build" : "matched (\(config!.targets.map(\.identifier).joined(separator: ", ")))")")

        // 2. SIP
        let sip = sipStatus()
        lines.append("SIP:          \(sip.rawValue)")

        // 3. running / ownership
        let running = Command.isRunning(app: app)
        lines.append("Running:      \(running ? "yes — quit it before patching" : "no")")
        let dylib = app.appendingPathComponent(Command.dylibBinary)
        let writable = fm.isWritableFile(atPath: app.path) && (!fm.fileExists(atPath: dylib.path) || fm.isWritableFile(atPath: dylib.path))
        lines.append("Writable:     \(writable ? "yes — no sudo needed" : "no — run patch with sudo")")
        let access = WriteAccess.inspect(app: app)
        let accessAdvice = WriteAccess.advice(access, app: app)
        if !access.blockers.isEmpty {
            lines.append("Write access: \(access.codes)")
            accessAdvice.forEach { lines.append("              " + $0) }
        }

        // 4. signature + entitlements
        let sig = capture("/usr/bin/codesign", ["-dvv", app.path])
        let authority = sig.split(separator: "\n").first { $0.hasPrefix("Authority=") }.map { String($0.dropFirst("Authority=".count)) }
        let adhoc = sig.contains("Signature=adhoc")
        let signature = adhoc ? "ad-hoc (already re-signed by a tool)" : (authority ?? "unreadable")
        lines.append("Signature:    \(signature)")

        let mainEnts = entitlementKeys(at: app)
        let sandboxed = mainEnts?.contains("com.apple.security.app-sandbox") ?? false
        let hasTeam = mainEnts?.contains("com.apple.application-identifier") ?? false
        let libValidationOff = mainEnts?.contains("com.apple.security.cs.disable-library-validation") ?? false
        if let keys = mainEnts {
            lines.append("Entitlements: main executable has \(keys.count) keys (app-sandbox \(sandboxed ? "✓" : "✗"), application-identifier \(hasTeam ? "✓" : "✗"), disable-library-validation \(libValidationOff ? "✓" : "–"))")
        } else {
            lines.append("Entitlements: main executable has NONE")
        }
        let nested = Resigner.codeSigningCandidates(in: app).filter {
            ["app", "appex", "xpc"].contains($0.pathExtension.lowercased()) && $0.standardizedFileURL.path != app.standardizedFileURL.path
        }
        let strippedNested = nested.filter { entitlementKeys(at: $0) == nil }
        if !nested.isEmpty {
            lines.append("              nested app/appex/xpc: \(nested.count), \(strippedNested.count) without entitlements (some helpers ship none even pristine — informational; the verdict keys off the main executable)")
        }
        let stripped = mainEnts == nil || !sandboxed || !hasTeam

        // 5. Sparkle prefs (informational — the binary block is what actually holds)
        let sparkle = [
            "SUEnableAutomaticChecks": defaultsRead("SUEnableAutomaticChecks"),
            "SUAutomaticallyUpdate": defaultsRead("SUAutomaticallyUpdate"),
            "SULastCheckTime": defaultsRead("SULastCheckTime"),
        ]
        lines.append("Sparkle:      SUEnableAutomaticChecks=\(sparkle["SUEnableAutomaticChecks"]!) SUAutomaticallyUpdate=\(sparkle["SUAutomaticallyUpdate"]!) SULastCheckTime=\(sparkle["SULastCheckTime"]!)")

        // 6. patch state
        var silent: Patcher.State?, keeptip: Patcher.State?, update: Patcher.State?
        var updateSource = "config.json"
        var updateNotApplicable = false
        var updateUnavailable = false
        // Targets that exist for this build but carry no entry for the slice this Mac runs.
        var archMissing: Set<String> = []
        if let config {
            func state(of identifier: String) -> Patcher.State? {
                guard let t = config.targets.first(where: { $0.identifier == identifier }) else { return nil }
                // Judge the slice this Mac executes. The other slice being patched (or not)
                // says nothing about whether recalls are blocked here.
                let entries = t.entries.filter { $0.arch == hostArch }
                guard !entries.isEmpty else { archMissing.insert(identifier); return nil }
                let binary = app.appendingPathComponent(t.binary ?? Command.defaultBinary)
                guard let insp = try? Patcher.inspect(binary: binary, entries: entries) else { return .unknown }
                if insp.allSatisfy({ $0.state == .patched }) { return .patched }
                // A "restore" entry (keeptip's cbz: asm is itself one of the accepted originals) reads
                // as .patched on a pristine binary; that is still the pristine picture for the target.
                let pristineLike = insp.allSatisfy {
                    $0.state == .pristine || ($0.state == .patched && $0.entry.expected.contains($0.entry.asm))
                }
                return pristineLike ? .pristine : .unknown
            }
            silent = state(of: Command.silentRevokeIdentifier)
            keeptip = state(of: Command.keeptipRevokeIdentifier)
            update = state(of: Command.updateIdentifier)
            if archMissing.contains(Command.updateIdentifier) || (update == nil && Command.isWeChat4(config) && hostArch != .arm64) {
                // The live locator below reads arm64 code only.
                updateUnavailable = true
                updateSource = Command.updateUnavailableNote(Command.archUnsupportedNote(build: config.version, arch: hostArch, feature: "update block"))
            } else if update == nil, Command.isWeChat4(config), fm.fileExists(atPath: dylib.path) {
                // Not curated for this build yet — the locator can still tell us the live state.
                do {
                    let hits = try UpdateLocator.locate(binary: dylib)
                    let patched = Set(hits.map(\.alreadyPatched))
                    update = patched.count == 1 ? (patched.first! ? .patched : .pristine) : .unknown
                    updateSource = "auto-located (not in config.json yet)"
                } catch where Command.updaterAbsentOnAppStore(app: app, error: error) {
                    updateNotApplicable = true
                    updateSource = Command.appStoreUpdateNote
                } catch {
                    updateUnavailable = true
                    updateSource = Command.updateUnavailableNote(error.localizedDescription)
                }
            } else if update == nil, !Command.isWeChat4(config) {
                let legacy = config.targets.filter { Command.legacyUpdateIdentifiers.contains($0.identifier) }
                if legacy.isEmpty {
                    updateNotApplicable = true
                    updateSource = "config.json has no updater patch points for this 3.x build"
                } else {
                    let states = Set(legacy.map { state(of: $0.identifier) })
                    update = states.count == 1 ? states.first! : .unknown
                }
            }
        }
        func show(_ s: Patcher.State?) -> String { s.map(\.rawValue) ?? "n/a" }
        lines.append("Anti-revoke:  silent=\(show(silent)) keeptip=\(show(keeptip))")
        let updateLabel = updateNotApplicable ? "not applicable" : (updateUnavailable ? "unavailable" : show(update))
        lines.append("Update block: \(updateLabel)  [\(updateSource)]")
        let updateImpossible = updateNotApplicable || updateUnavailable
        // Anti-revoke is the product: if neither revoke variant has patch points for this
        // Mac's architecture, the build is unsupported *here*, whatever the other slice has.
        let revokeArchMissing = config != nil && silent == nil && keeptip == nil
            && !archMissing.isDisjoint(with: [Command.silentRevokeIdentifier, Command.keeptipRevokeIdentifier])
        if revokeArchMissing {
            lines.append("Architecture: \(hostArch.rawValue) — no anti-revoke patch points for this architecture in build \(version ?? "?")")
        }

        // 7. verdict — one decision, rendered twice (text + Status.overall)
        var verdict: [String] = []
        switch sip {
        case .enabled:
            verdict.append("SIP is ON: macOS enforces entitlements. A bundle whose entitlements were stripped is killed at launch (that was #1038). This tool's default resign keeps them; never use `codesign --remove-sign` / a bare `--deep --sign -` on this machine.")
        case .disabled:
            verdict.append("SIP is OFF: a broken signature still launches here, so \"it opens\" on this Mac proves nothing for SIP-on machines. Judge by the Entitlements line above, not by whether WeChat starts.")
        case .unknown:
            verdict.append("SIP status unreadable (csrutil failed) — assume ON.")
        }

        let sudo = writable ? "" : "sudo "
        let revokeOn = silent == .patched ? "silent" : (keeptip == .patched ? "keeptip" : nil)
        let unknowns = [silent, keeptip, update].contains { $0 == .unknown }
        var overall: Status.Overall
        var nextCommand: String?

        if stripped {
            overall = .brokenBundle
            if sip == .enabled {
                verdict.append("❌ Bundle has lost its entitlements — WeChat will not start on this machine. Reinstall WeChat from https://mac.weixin.qq.com first, then run patch.")
            } else {
                verdict.append("⚠️ Bundle has lost its entitlements (old resign flow). It runs only because SIP is off; sandbox/camera/mic/app-group grants are gone. Reinstall WeChat from https://mac.weixin.qq.com, then run patch.")
            }
        } else if config == nil {
            overall = .unsupportedBuild
            verdict.append("❌ Build \(version ?? "?") is not in config.json. From the repo: python3 tools/sync_ref.py && python3 tools/locate_revoke.py --append && python3 tools/locate_update.py --append && swift build -c release")
        } else if revokeArchMissing {
            overall = .unsupportedBuild
            verdict.append("❌ Build \(version ?? "?") is supported on the other architecture only: config.json has no \(hostArch.rawValue) anti-revoke patch points for it, and this Mac runs WeChat's \(hostArch.rawValue) code. Patching would leave WeChat behaving exactly as it does now, so nothing is offered.")
        } else if unknowns {
            overall = .mixed
            verdict.append("⚠️ Some patch points hold bytes that are neither pristine nor patched — mixed builds or a foreign patch. Reinstall WeChat, then patch.")
        } else if revokeOn != nil && update == .patched {
            overall = .protected
            verdict.append("✅ Anti-revoke (\(revokeOn!)) and update block are both applied. The only real test of anti-revoke is receiving a recalled message.")
        } else if revokeOn != nil && updateImpossible {
            overall = .antiRevokeOnly
            verdict.append("✅ Anti-revoke (\(revokeOn!)) is applied. Update block: \(updateSource). The only real test of anti-revoke is receiving a recalled message.")
        } else {
            overall = (revokeOn == nil && update != .patched) ? .unprotected : .partial
            var todo: [String] = []
            if revokeOn == nil { todo.append("anti-revoke") }
            if update != .patched && !updateImpossible { todo.append("update block") }
            if updateImpossible { verdict.append("ℹ️ Update block: \(updateSource).") }
            nextCommand = "\(sudo)wechattweak patch --variant keeptip"
            // A lock, a deny ACL or a read-only volume stops the patch even under sudo: say so
            // before the command, with the fix, instead of letting the run fail on it.
            let hardBlockers = access.blockers.filter { $0 != .needsAdmin }
            if !hardBlockers.isEmpty {
                verdict.append("🔒 Fix this first, the patch cannot write otherwise:")
                zip(access.blockers, accessAdvice).filter { $0.0 != .needsAdmin }.forEach { verdict.append("   " + $0.1) }
            }
            verdict.append("➡️ Missing: \(todo.joined(separator: " + ")). \(running ? "Quit WeChat (wait until `pgrep -x WeChat` prints nothing), then run:" : "Run:")  \(nextCommand!)")
        }

        let status = Status(
            overall: overall,
            build: version,
            fullVersion: versions.full,
            shortVersion: versions.short,
            installChannel: channel,
            hostArch: hostArch.rawValue,
            archSupported: !revokeArchMissing,
            appPath: app.path,
            configKnown: config != nil,
            configTargets: config?.targets.map(\.identifier) ?? [],
            sip: sip,
            running: running,
            writable: writable,
            writeBlockers: access.blockers.map(\.rawValue),
            writeAccess: access.items,
            signature: signature,
            entitlementsOK: !stripped,
            entitlementKeyCount: mainEnts?.count ?? 0,
            antiRevokeSilent: silent?.rawValue,
            antiRevokeKeeptip: keeptip?.rawValue,
            updateBlock: updateNotApplicable ? "notApplicable" : (updateUnavailable ? "unavailable" : update?.rawValue),
            updateSource: updateSource,
            sparkle: sparkle,
            verdict: verdict,
            nextCommand: nextCommand
        )
        return Report(status: status, lines: lines)
    }

    // MARK: - probes

    static func sipStatus() -> SIP {
        let out = capture("/usr/bin/csrutil", ["status"]).lowercased()
        if out.contains("status: enabled") { return .enabled }
        if out.contains("status: disabled") { return .disabled }
        return .unknown
    }

    /// Entitlement keys of a code object; nil = no entitlements at all (or unreadable).
    static func entitlementKeys(at url: URL) -> [String]? {
        guard let outer = try? Resigner.inspectEntitlements(at: url), let plist = outer,
              let dict = (try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil)) as? [String: Any],
              !dict.isEmpty else { return nil }
        return Array(dict.keys)
    }

    private static func defaultsRead(_ key: String) -> String {
        let v = capture("/usr/bin/defaults", ["read", "com.tencent.xinWeChat", key]).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty || v.contains("does not exist") ? "unset" : v
    }

    private static func capture(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

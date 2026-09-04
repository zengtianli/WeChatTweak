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
            /// One of the two is applied, the other is not.
            case partial
            /// Nothing applied, and nothing is in the way.
            case unprotected
        }

        var overall: Overall
        var build: String?
        var appPath: String
        var configKnown: Bool
        var configTargets: [String]
        var sip: SIP
        var running: Bool
        /// false → the patch must run with sudo.
        var writable: Bool
        var signature: String
        var entitlementsOK: Bool
        var entitlementKeyCount: Int
        /// `patched` / `pristine` / `unknown` / nil when the build has no such target.
        var antiRevokeSilent: String?
        var antiRevokeKeeptip: String?
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

    static func run(app: URL, configs: [Config]) async throws -> Report {
        let fm = FileManager.default
        var lines: [String] = []

        // 1. build + config
        let version = try await Command.version(app: app)
        let config = configs.first { $0.version == version }
        lines.append("WeChat build: \(version ?? "unknown")  (\(app.path))")
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
        if let config {
            func state(of identifier: String) -> Patcher.State? {
                guard let t = config.targets.first(where: { $0.identifier == identifier }) else { return nil }
                let binary = app.appendingPathComponent(t.binary ?? Command.defaultBinary)
                guard let insp = try? Patcher.inspect(binary: binary, entries: t.entries) else { return .unknown }
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
            if update == nil, Command.isWeChat4(config), fm.fileExists(atPath: dylib.path) {
                // Not curated for this build yet — the locator can still tell us the live state.
                if let hits = try? UpdateLocator.locate(binary: dylib) {
                    let patched = Set(hits.map(\.alreadyPatched))
                    update = patched.count == 1 ? (patched.first! ? .patched : .pristine) : .unknown
                    updateSource = "auto-located (not in config.json yet)"
                }
            }
        }
        func show(_ s: Patcher.State?) -> String { s.map(\.rawValue) ?? "n/a" }
        lines.append("Anti-revoke:  silent=\(show(silent)) keeptip=\(show(keeptip))")
        lines.append("Update block: \(show(update))  [\(updateSource)]")

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
        } else if unknowns {
            overall = .mixed
            verdict.append("⚠️ Some patch points hold bytes that are neither pristine nor patched — mixed builds or a foreign patch. Reinstall WeChat, then patch.")
        } else if revokeOn != nil && update == .patched {
            overall = .protected
            verdict.append("✅ Anti-revoke (\(revokeOn!)) and update block are both applied. The only real test of anti-revoke is receiving a recalled message.")
        } else {
            overall = (revokeOn == nil && update != .patched) ? .unprotected : .partial
            var todo: [String] = []
            if revokeOn == nil { todo.append("anti-revoke") }
            if update != .patched { todo.append("update block") }
            nextCommand = "\(sudo)wechattweak patch --variant keeptip"
            verdict.append("➡️ Missing: \(todo.joined(separator: " + ")). \(running ? "Quit WeChat (wait until `pgrep -x WeChat` prints nothing), then run:" : "Run:")  \(nextCommand!)")
        }

        let status = Status(
            overall: overall,
            build: version,
            appPath: app.path,
            configKnown: config != nil,
            configTargets: config?.targets.map(\.identifier) ?? [],
            sip: sip,
            running: running,
            writable: writable,
            signature: signature,
            entitlementsOK: !stripped,
            entitlementKeyCount: mainEnts?.count ?? 0,
            antiRevokeSilent: silent?.rawValue,
            antiRevokeKeeptip: keeptip?.rawValue,
            updateBlock: update?.rawValue,
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

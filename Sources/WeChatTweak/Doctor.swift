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

import Foundation

struct Doctor {
    enum SIP: String { case enabled, disabled, unknown }

    struct Report {
        var lines: [String] = []
        var verdict: [String] = []
        var text: String {
            (["------ Doctor ------"] + lines + ["------ Verdict ------"] + verdict).joined(separator: "\n")
        }
    }

    static func run(app: URL, configs: [Config]) async throws -> Report {
        var r = Report()
        let fm = FileManager.default

        // 1. build + config
        let version = try await Command.version(app: app)
        let config = configs.first { $0.version == version }
        r.lines.append("WeChat build: \(version ?? "unknown")  (\(app.path))")
        r.lines.append("config.json:  \(config == nil ? "NO entry for this build" : "matched (\(config!.targets.map(\.identifier).joined(separator: ", ")))")")

        // 2. SIP
        let sip = sipStatus()
        r.lines.append("SIP:          \(sip.rawValue)")

        // 3. running / ownership
        let running = Command.isRunning(app: app)
        r.lines.append("Running:      \(running ? "yes — quit it before patching" : "no")")
        let dylib = app.appendingPathComponent("Contents/Resources/wechat.dylib")
        let writable = fm.isWritableFile(atPath: app.path) && (!fm.fileExists(atPath: dylib.path) || fm.isWritableFile(atPath: dylib.path))
        r.lines.append("Writable:     \(writable ? "yes — no sudo needed" : "no — run patch with sudo")")

        // 4. signature + entitlements
        let sig = capture("/usr/bin/codesign", ["-dvv", app.path])
        let authority = sig.split(separator: "\n").first { $0.hasPrefix("Authority=") }.map { String($0.dropFirst("Authority=".count)) }
        let adhoc = sig.contains("Signature=adhoc")
        r.lines.append("Signature:    \(adhoc ? "ad-hoc (already re-signed by a tool)" : (authority ?? "unreadable"))")

        let mainEnts = entitlementKeys(at: app)
        let sandboxed = mainEnts?.contains("com.apple.security.app-sandbox") ?? false
        let hasTeam = mainEnts?.contains("com.apple.application-identifier") ?? false
        let libValidationOff = mainEnts?.contains("com.apple.security.cs.disable-library-validation") ?? false
        if let keys = mainEnts {
            r.lines.append("Entitlements: main executable has \(keys.count) keys (app-sandbox \(sandboxed ? "✓" : "✗"), application-identifier \(hasTeam ? "✓" : "✗"), disable-library-validation \(libValidationOff ? "✓" : "–"))")
        } else {
            r.lines.append("Entitlements: main executable has NONE")
        }
        let nested = Resigner.codeSigningCandidates(in: app).filter {
            ["app", "appex", "xpc"].contains($0.pathExtension.lowercased()) && $0.standardizedFileURL.path != app.standardizedFileURL.path
        }
        let strippedNested = nested.filter { entitlementKeys(at: $0) == nil }
        if !nested.isEmpty {
            r.lines.append("              nested app/appex/xpc: \(nested.count), \(strippedNested.count) without entitlements (some helpers ship none even pristine — informational; the verdict keys off the main executable)")
        }
        let stripped = mainEnts == nil || !sandboxed || !hasTeam

        // 5. Sparkle prefs (informational — the binary block is what actually holds)
        let suChecks = defaultsRead("SUEnableAutomaticChecks"), suAuto = defaultsRead("SUAutomaticallyUpdate"), suLast = defaultsRead("SULastCheckTime")
        r.lines.append("Sparkle:      SUEnableAutomaticChecks=\(suChecks) SUAutomaticallyUpdate=\(suAuto) SULastCheckTime=\(suLast)")

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
        r.lines.append("Anti-revoke:  silent=\(show(silent)) keeptip=\(show(keeptip))")
        r.lines.append("Update block: \(show(update))  [\(updateSource)]")

        // 7. verdict
        let sudo = writable ? "" : "sudo "
        switch sip {
        case .enabled:
            r.verdict.append("SIP is ON: macOS enforces entitlements. A bundle whose entitlements were stripped is killed at launch (that was #1038). This tool's default resign keeps them; never use `codesign --remove-sign` / a bare `--deep --sign -` on this machine.")
        case .disabled:
            r.verdict.append("SIP is OFF: a broken signature still launches here, so \"it opens\" on this Mac proves nothing for SIP-on machines. Judge by the Entitlements line above, not by whether WeChat starts.")
        case .unknown:
            r.verdict.append("SIP status unreadable (csrutil failed) — assume ON.")
        }
        if stripped {
            if sip == .enabled {
                r.verdict.append("❌ Bundle has lost its entitlements — WeChat will not start on this machine. Reinstall WeChat from https://mac.weixin.qq.com first, then run patch.")
            } else {
                r.verdict.append("⚠️ Bundle has lost its entitlements (old resign flow). It runs only because SIP is off; sandbox/camera/mic/app-group grants are gone. Reinstall WeChat from https://mac.weixin.qq.com, then run patch.")
            }
        }
        if config == nil {
            r.verdict.append("❌ Build \(version ?? "?") is not in config.json. From the repo: python3 tools/sync_ref.py && python3 tools/locate_revoke.py --append && python3 tools/locate_update.py --append && swift build -c release")
        } else {
            let revokeOn = silent == .patched ? "silent" : (keeptip == .patched ? "keeptip" : nil)
            let unknowns = [silent, keeptip, update].contains { $0 == .unknown }
            if let revokeOn, update == .patched {
                r.verdict.append("✅ Anti-revoke (\(revokeOn)) and update block are both applied. The only real test of anti-revoke is receiving a recalled message.")
            } else if unknowns {
                r.verdict.append("⚠️ Some patch points hold bytes that are neither pristine nor patched — mixed builds or a foreign patch. Reinstall WeChat, then patch.")
            } else {
                var todo: [String] = []
                if revokeOn == nil { todo.append("anti-revoke") }
                if update != .patched { todo.append("update block") }
                r.verdict.append("➡️ Missing: \(todo.joined(separator: " + ")). \(running ? "Quit WeChat (wait until `pgrep -x WeChat` prints nothing), then run:" : "Run:")  \(sudo)wechattweak patch --variant keeptip")
            }
        }
        return r
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

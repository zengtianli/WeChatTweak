//
//  Resigner.swift
//  WeChatTweak
//
//  Ad-hoc re-signing that keeps WeChat launchable on a stock (SIP-enabled) Mac.
//
//  WeChat 4.x ships App-Sandboxed + Hardened Runtime, with entitlements that carry
//  Tencent's Team ID (`com.apple.application-identifier = 5A4RE8SF68.…`) on the main
//  app, WeChatHelper, WeChatAppEx and every helper/appex inside. The old flow
//  (`codesign --remove-sign` + `--deep --sign -`) stripped the root's entitlements while
//  nested code kept theirs — fine on a machine with SIP off (where this was developed),
//  but on a stock Mac AMFI kills the app at launch (issue #1038, builds 269579+: "闪退").
//
//  This mirrors the flow fzlzjerry/wechat-antirecall validated across its users:
//    1. snapshot the entitlements of every signed code object in the bundle;
//    2. inject two keys into each non-empty profile so an ad-hoc identity can still run it:
//       - `com.apple.security.cs.disable-library-validation`: the re-signed frameworks are
//         Team-less while the main binary's entitlements still name Tencent's Team ID —
//         without this, loading the first framework aborts with "different Team IDs";
//       - `com.apple.security.cs.allow-unsigned-executable-memory`: at login wechat.dylib
//         jumps into plain mmap'd RX memory, which Hardened Runtime rejects (SIGKILL,
//         Namespace CODESIGNING) unless this is granted (`allow-jit` only covers MAP_JIT);
//    3. sign the patched dylib(s) first, then the whole bundle with
//       `--preserve-metadata=identifier,flags,runtime` (never `requirements`: they bind
//       the original Developer ID and would make nested code unacceptable to its parent);
//    4. re-read every profile; anything that drifted is restored explicitly, deepest code
//       object first, root last; still drifted → fail loudly (never report success on a
//       bundle whose sandbox / camera / mic / app-group profile silently vanished);
//    5. `codesign --verify --deep --strict`; quarantine strip is best-effort.
//

import Foundation

struct Resigner {
    enum Error: LocalizedError {
        case process(command: String, status: Int32, output: String)
        case entitlementsMismatch([String])

        var errorDescription: String? {
            switch self {
            case let .process(command, status, output):
                return "\(command) exited \(status)\n\(output)"
            case let .entitlementsMismatch(paths):
                return """
                    resign: \(paths.count) code object(s) lost or changed their entitlements after re-signing \
                    (sandbox / camera / mic / app-group profile) — refusing to call this a success:
                    \(paths.map { "  " + $0 }.joined(separator: "\n"))
                    """
            }
        }
    }

    /// Keys injected into every profile that already has entitlements (see file header).
    static let injectedEntitlements: [String: Bool] = [
        "com.apple.security.cs.disable-library-validation": true,
        "com.apple.security.cs.allow-unsigned-executable-memory": true,
    ]

    struct Snapshot {
        struct Entry {
            let url: URL
            /// Desired post-signing profile (original + injected keys); nil = had none.
            let plist: Data?
        }
        let entries: [Entry]

        func plist(for url: URL) -> Data? {
            let path = url.standardizedFileURL.path
            return entries.first { $0.url.standardizedFileURL.path == path }?.plist
        }
    }

    // MARK: - Entry point

    static func resign(app: URL, patchedBinaries: [URL]) throws {
        let snapshot = try capture(app: app)
        print(String(format: "[resign] %d signed code objects, %d with entitlements",
                     snapshot.entries.count, snapshot.entries.filter { $0.plist != nil }.count))

        // Patched nested binaries first, so the modified dylib already carries a valid
        // ad-hoc signature before the bundle-level --deep pass wraps it.
        for binary in patchedBinaries where binary.standardizedFileURL.path != app.standardizedFileURL.path {
            try signMachO(binary, entitlements: snapshot.plist(for: binary))
        }

        // Root pass WITHOUT --entitlements: supplying the root plist together with --deep
        // would also stamp it onto nested code that originally had none.
        try codesign(app, deep: true, entitlements: nil)

        var drifted = try mismatches(snapshot)
        if !drifted.isEmpty {
            print("[resign] \(drifted.count) profile(s) drifted after --deep pass, restoring explicitly")
            try restore(snapshot, app: app)
            drifted = try mismatches(snapshot)
            guard drifted.isEmpty else { throw Error.entitlementsMismatch(drifted) }
        }

        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", app.path])
        print("[resign] codesign --verify --deep --strict: OK")

        // Best-effort: WeChat ships read-only nested files (0444 gpu_shader_cache.bin) and
        // macOS 15+ adds an OS-protected com.apple.provenance xattr; either makes xattr(1)
        // fail with EACCES/EPERM on an otherwise valid, signed bundle.
        if (try? run("/usr/bin/xattr", ["-cr", app.path])) == nil {
            print("[resign] warning: xattr -cr could not clear every nested file; signature is valid, ignoring")
        }
    }

    // MARK: - Snapshot / compare / restore

    static func capture(app: URL) throws -> Snapshot {
        var entries: [Snapshot.Entry] = []
        for candidate in codeSigningCandidates(in: app) {
            guard let current = try inspectEntitlements(at: candidate) else { continue }  // unsigned → skip
            entries.append(.init(url: candidate, plist: inject(current)))
        }
        return Snapshot(entries: entries)
    }

    static func mismatches(_ snapshot: Snapshot) throws -> [String] {
        var bad: [String] = []
        for entry in snapshot.entries {
            guard let current = try inspectEntitlements(at: entry.url) else {
                bad.append(entry.url.path); continue
            }
            switch (entry.plist, current) {
            case (nil, nil): break
            case let (want?, have?) where plistsEqual(want, have): break
            default: bad.append(entry.url.path)
            }
        }
        return bad.sorted()
    }

    private static func restore(_ snapshot: Snapshot, app: URL) throws {
        let withProfile = snapshot.entries.filter { $0.plist != nil }.map { $0.url.standardizedFileURL.path }
        // Ancestors of a profiled object must be re-sealed too (their resource envelope changed).
        let toRestore = snapshot.entries.filter { entry in
            let p = entry.url.standardizedFileURL.path
            return entry.plist != nil || withProfile.contains { $0.hasPrefix(p + "/") }
        }
        let deepestFirst = toRestore.sorted {
            let l = $0.url.standardizedFileURL.pathComponents.count, r = $1.url.standardizedFileURL.pathComponents.count
            return l == r ? $0.url.path > $1.url.path : l > r
        }
        for entry in deepestFirst {
            try signMachO(entry.url, entitlements: entry.plist)
        }
    }

    // MARK: - codesign

    private static func signMachO(_ url: URL, entitlements: Data?) throws {
        do {
            try codesign(url, deep: false, entitlements: entitlements)
        } catch {
            // In-place signing can fail on a read-only/locked file; sign a temp copy and cp -p it back.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("wechattweak-sign-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let tmp = dir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: tmp)
            try codesign(tmp, deep: false, entitlements: entitlements)
            try run("/bin/cp", ["-p", tmp.path, url.path])
        }
    }

    private static func codesign(_ url: URL, deep: Bool, entitlements: Data?) throws {
        var args = ["--force"]
        if deep { args.append("--deep") }
        args.append("--preserve-metadata=identifier,flags,runtime")
        args += ["--sign", "-"]
        var tmpDir: URL?
        defer { if let d = tmpDir { try? FileManager.default.removeItem(at: d) } }
        if let entitlements {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("wechattweak-ent-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            tmpDir = dir
            let plist = dir.appendingPathComponent("entitlements.plist")
            try entitlements.write(to: plist, options: .atomic)
            if ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 15, minorVersion: 0, patchVersion: 0)) {
                args.append("--force-library-entitlements")  // macOS 15+ drops supplied entitlements on libraries otherwise
            }
            args += ["--entitlements", plist.path]
        }
        args.append(url.path)
        try run("/usr/bin/codesign", args)
    }

    // MARK: - Bundle walk / inspection

    static func codeSigningCandidates(in app: URL) -> [URL] {
        let bundles: Set<String> = ["app", "appex", "bundle", "framework", "plugin", "service", "xpc"]
        let loose: Set<String> = ["dylib", "so"]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var out: [URL] = [app]
        var seen: Set<String> = [app.standardizedFileURL.path]
        guard let e = FileManager.default.enumerator(at: app, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return out }
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: keys), v.isSymbolicLink != true else { continue }
            let ext = url.pathExtension.lowercased()
            let isCode = (v.isDirectory == true && bundles.contains(ext))
                || (v.isRegularFile == true && (loose.contains(ext) || FileManager.default.isExecutableFile(atPath: url.path)))
            guard isCode, seen.insert(url.standardizedFileURL.path).inserted else { continue }
            out.append(url)
        }
        return out
    }

    /// nil = not signed code (skip). Empty entitlements are reported as `.some(nil)`.
    static func inspectEntitlements(at url: URL) throws -> Data?? {
        let r = capture("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", url.path])
        guard r.status == 0 else { return nil }
        return .some(r.stdout.isEmpty ? nil : r.stdout)
    }

    static func inject(_ plist: Data?) -> Data? {
        guard let plist,
              var dict = (try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil)) as? [String: Any]
        else { return plist }
        for (k, v) in injectedEntitlements { dict[k] = v }
        return (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)) ?? plist
    }

    static func plistsEqual(_ a: Data, _ b: Data) -> Bool {
        guard let x = try? PropertyListSerialization.propertyList(from: a, options: [], format: nil) as? NSDictionary,
              let y = try? PropertyListSerialization.propertyList(from: b, options: [], format: nil) as? NSDictionary
        else { return a == b }
        return x.isEqual(y)
    }

    // MARK: - Process

    private struct Captured { let status: Int32; let stdout: Data; let stderr: Data }

    private static func capture(_ path: String, _ args: [String]) -> Captured {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return Captured(status: 127, stdout: Data(), stderr: Data(error.localizedDescription.utf8)) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Captured(status: p.terminationStatus, stdout: o, stderr: e)
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) throws -> String {
        let r = capture(path, args)
        let text = String(decoding: r.stdout + r.stderr, as: UTF8.self)
        guard r.status == 0 else { throw Error.process(command: ([path] + args).joined(separator: " "), status: r.status, output: text) }
        return text
    }
}

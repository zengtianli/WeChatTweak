//
//  LocalIdentity.swift
//  WeChatTweak
//
//  A code-signing identity that lives only on this Mac, so the re-signed WeChat keeps the
//  SAME identity across every patch, variant switch, restore and WeChat update.
//
//  Why: macOS ties privacy grants (Screen Recording, Microphone, Camera …) to the app's
//  designated requirement. An ad-hoc signature has none of its own — its requirement is
//  `cdhash H"…"`, which changes whenever any byte of the bundle changes (silent ↔ keeptip
//  alone flips it). The grant then silently stops matching while System Settings still shows
//  the switch ON, and WeChat reports "录屏权限未开启" (WeChatUnrevoke #13). Signed with this
//  identity the requirement becomes `identifier "com.tencent.xinWeChat" and certificate
//  leaf = H"<this Mac's cert>"`, which survives re-patching.
//
//  The identity is a self-signed certificate + private key in a dedicated keychain file
//  under the invoking user's Application Support. It never enters the user's keychain search
//  list, has an empty password (the file's 0600 permissions are the protection, same as the
//  login keychain's), and is created once.
//

import Foundation

struct LocalIdentity {
    /// SHA-1 of the certificate — what `codesign --sign` and the designated requirement use.
    let sha1: String
    let keychain: URL

    static let commonName = "WeChatTweak Local Signing"

    enum Error: LocalizedError {
        case step(String, String)
        var errorDescription: String? {
            switch self {
            case let .step(what, output): return "local signing identity: \(what) failed\n\(output)"
            }
        }
    }

    // MARK: - Location

    /// The human user this run acts for. Under `sudo` that is SUDO_USER; under an
    /// AppleScript "with administrator privileges" (WeChatUnrevoke's admin path) there is no
    /// SUDO_USER, so fall back to the console user.
    static func realUser() -> (name: String, home: URL, uid: uid_t, gid: gid_t)? {
        var candidates: [String] = []
        if getuid() == 0 {
            if let s = ProcessInfo.processInfo.environment["SUDO_USER"], !s.isEmpty, s != "root" { candidates.append(s) }
            if let console = consoleUser() { candidates.append(console) }
        } else if let pw = getpwuid(getuid()) {
            candidates.append(String(cString: pw.pointee.pw_name))
        }
        for name in candidates {
            guard let pw = getpwnam(name) else { continue }
            return (name, URL(fileURLWithPath: String(cString: pw.pointee.pw_dir), isDirectory: true), pw.pointee.pw_uid, pw.pointee.pw_gid)
        }
        return nil
    }

    private static func consoleUser() -> String? {
        var st = stat()
        guard stat("/dev/console", &st) == 0, st.st_uid != 0, let pw = getpwuid(st.st_uid) else { return nil }
        return String(cString: pw.pointee.pw_name)
    }

    static func directory(home: URL) -> URL {
        // Tests point this at a throwaway folder so they never create the real identity.
        if let dir = ProcessInfo.processInfo.environment["WECHATTWEAK_SIGNING_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/WeChatTweak/signing", isDirectory: true)
    }

    // MARK: - Lookup / creation

    /// The existing identity, without creating anything.
    static func existing() -> LocalIdentity? {
        guard let user = realUser() else { return nil }
        let keychain = directory(home: user.home).appendingPathComponent("signing.keychain-db")
        guard FileManager.default.fileExists(atPath: keychain.path) else { return nil }
        return find(in: keychain)
    }

    /// The identity, created on first use.
    static func ensure() throws -> LocalIdentity {
        if let found = existing() { return found }
        guard let user = realUser() else { throw Error.step("finding the user to own the identity", "no SUDO_USER / console user") }
        let dir = directory(home: user.home)
        let keychain = dir.appendingPathComponent("signing.keychain-db")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A half-made keychain from an interrupted run would make create-keychain fail.
        if fm.fileExists(atPath: keychain.path) { try? fm.removeItem(at: keychain) }

        let work = fm.temporaryDirectory.appendingPathComponent("wechattweak-identity-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }

        let cnf = work.appendingPathComponent("req.cnf")
        try """
        [req]
        distinguished_name=dn
        x509_extensions=v3
        prompt=no
        [dn]
        CN=\(commonName) (\(user.name))
        [v3]
        basicConstraints=critical,CA:false
        keyUsage=critical,digitalSignature
        extendedKeyUsage=critical,codeSigning
        """.write(to: cnf, atomically: true, encoding: .utf8)
        let key = work.appendingPathComponent("key.pem"), cert = work.appendingPathComponent("cert.pem")
        let p12 = work.appendingPathComponent("identity.p12")
        // /usr/bin/openssl is the system LibreSSL: its PKCS#12 defaults are what `security import`
        // reads (a Homebrew OpenSSL 3 would need -legacy), so never take openssl from PATH.
        try step("creating the certificate", "/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
            "-days", "7300", "-keyout", key.path, "-out", cert.path, "-config", cnf.path])
        try step("packaging the certificate", "/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key.path, "-in", cert.path,
            "-out", p12.path, "-passout", "pass:wechattweak", "-name", commonName])

        // `create-keychain` also appends the new file to the caller's search list; put the list back
        // exactly as it was so the identity never shows up in Keychain Access or other lookups.
        let before = searchList()
        try step("creating the keychain", "/usr/bin/security", ["create-keychain", "-p", "", keychain.path])
        if let before { restoreSearchList(before) }
        try step("configuring the keychain", "/usr/bin/security", ["set-keychain-settings", keychain.path])  // no auto-lock
        try step("unlocking the keychain", "/usr/bin/security", ["unlock-keychain", "-p", "", keychain.path])
        try step("importing the identity", "/usr/bin/security", ["import", p12.path, "-k", keychain.path, "-P", "wechattweak",
            "-T", "/usr/bin/codesign"])
        // Lets codesign use the key without a "codesign wants to access key" prompt.
        try step("allowing codesign to use the key", "/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
            "-s", "-k", "", keychain.path])

        if getuid() == 0 {  // created by root on the user's behalf: hand it back
            for path in [dir.deletingLastPathComponent().path, dir.path, keychain.path] {
                chown(path, user.uid, user.gid)
            }
        }
        chmod(keychain.path, 0o600)
        guard let made = find(in: keychain) else {
            throw Error.step("reading back the new identity", "security find-identity found no identity in \(keychain.path)")
        }
        print("[resign] created this Mac's signing identity (\(made.sha1.prefix(8))…) in \(keychain.path)")
        return made
    }

    /// Unlock right before signing: a keychain can be locked again by sleep or another user session.
    func unlock() {
        _ = LocalIdentity.capture("/usr/bin/security", ["unlock-keychain", "-p", "", keychain.path])
    }

    private static func find(in keychain: URL) -> LocalIdentity? {
        _ = capture("/usr/bin/security", ["unlock-keychain", "-p", "", keychain.path])
        // Untrusted (self-signed) identities are listed under "Matching identities" only, so no -v.
        let out = capture("/usr/bin/security", ["find-identity", "-p", "codesigning", keychain.path]).output
        for line in out.split(separator: "\n") where line.contains(commonName) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[1].count == 40, parts[1].allSatisfy(\.isHexDigit) {
                return LocalIdentity(sha1: String(parts[1]), keychain: keychain)
            }
        }
        return nil
    }

    // MARK: - Search list

    private static func searchList() -> [String]? {
        let r = capture("/usr/bin/security", ["list-keychains", "-d", "user"])
        guard r.status == 0 else { return nil }
        return r.output.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }.filter { !$0.isEmpty }
    }

    private static func restoreSearchList(_ list: [String]) {
        guard let now = searchList(), now != list, !list.isEmpty else { return }
        _ = capture("/usr/bin/security", ["list-keychains", "-d", "user", "-s"] + list)
    }

    // MARK: - Process

    private static func step(_ what: String, _ exe: String, _ args: [String]) throws {
        let r = capture(exe, args)
        guard r.status == 0 else { throw Error.step(what, r.output) }
    }

    static func capture(_ exe: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (127, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

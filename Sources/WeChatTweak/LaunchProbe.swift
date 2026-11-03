//
//  LaunchProbe.swift
//  WeChatTweak
//
//  Asks the kernel whether a re-signed executable would be allowed to start, without running
//  any of its code: posix_spawn with POSIX_SPAWN_START_SUSPENDED goes through the full
//  exec-time code-signing / entitlement validation (AMFI kills a refused binary right there
//  with SIGKILL), then the suspended process is killed before it executes an instruction.
//  Used after signing with this Mac's identity: if anything would be refused, fall back to
//  the ad-hoc signature that is known to launch.
//

import Foundation

enum LaunchProbe {
    struct Refusal: CustomStringConvertible {
        let path: String
        let reason: String
        var description: String { "\(path): \(reason)" }
    }

    /// Main executable of the app and of every nested .app (helpers launch on their own).
    static func executables(in app: URL) -> [URL] {
        var out: [URL] = []
        for bundle in [app] + Resigner.codeSigningCandidates(in: app).filter({ $0.pathExtension.lowercased() == "app" && $0.standardizedFileURL.path != app.standardizedFileURL.path }) {
            if let exe = Bundle(url: bundle)?.executableURL, FileManager.default.isExecutableFile(atPath: exe.path) {
                out.append(exe)
            }
        }
        return out
    }

    static func refusals(in app: URL) -> [Refusal] {
        executables(in: app).compactMap { probe($0) }
    }

    /// nil = the kernel accepted it.
    static func probe(_ exe: URL) -> Refusal? {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_START_SUSPENDED))
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe.path), nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawn(&pid, exe.path, nil, &attr, argv, nil)
        guard rc == 0 else { return Refusal(path: exe.path, reason: "spawn refused: \(String(cString: strerror(rc)))") }
        // AMFI decides during exec; give a refusal time to land.
        var status: Int32 = 0
        for _ in 0..<10 {
            usleep(100_000)
            if waitpid(pid, &status, WNOHANG) == pid {
                let signal = status & 0x7f
                return Refusal(path: exe.path, reason: signal != 0 ? "killed at launch (signal \(signal)) — signature or entitlements refused" : "exited at launch (status \(status >> 8))")
            }
        }
        kill(pid, SIGKILL)
        waitpid(pid, &status, 0)
        return nil
    }
}

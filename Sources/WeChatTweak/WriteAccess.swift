//
//  WriteAccess.swift
//  WeChatTweak
//
//  "Permission denied" on a WeChat file has five unrelated causes, and each has a different
//  fix. Telling a user to grant App Management when the bundle is merely root-owned (or
//  locked in Finder) sends them in circles — issue #1 collected exactly that. So the engine
//  says which one it is, from what the filesystem itself reports:
//
//    · needsAdmin      owner/mode: this user has no POSIX write access → run with sudo
//    · immutable       uchg/schg/uappnd/sappnd flag → unlock; a password does not bypass it
//    · aclDeny         an ACL entry denies writing → remove that entry
//    · readOnlyVolume  WeChat is on a read-only volume (disk image / translocated copy)
//    · appManagement   none of the above explains a refusal that really happened → macOS
//                      App Management (TCC). This one is never reported from a read-only
//                      pass: probing for it would itself raise the system's "was prevented
//                      from modifying apps" alert on every `doctor`.
//
//  `inspect` is read-only (lstat / statfs / acl_get). `explain` is called only after a write
//  has actually failed.
//

import Darwin
import Foundation

struct WriteAccess {
    enum Blocker: String, Encodable, CaseIterable {
        case readOnlyVolume
        case immutable
        case aclDeny
        case needsAdmin
        case appManagement
    }

    /// One inspected path that has something in the way of a write.
    struct Item: Encodable, Equatable {
        var path: String
        var owner: String
        /// Octal permission bits, e.g. "755".
        var mode: String
        /// `uchg` / `schg` / `uappnd` / `sappnd` as `ls -lO` prints them.
        var flags: [String]
        var aclDeny: Bool
        /// Owner/group/other bits alone — flags, ACLs and TCC are judged separately.
        var posixWritable: Bool
    }

    struct Report: Encodable, Equatable {
        var blockers: [Blocker]
        /// Only the paths that carry a blocker; empty when nothing is in the way.
        var items: [Item]

        var codes: String { blockers.map(\.rawValue).joined(separator: ",") }
    }

    /// Bundle-relative paths a patch run writes into: the patched images, the directories
    /// that receive the `.bak` backup, and what `codesign` rewrites afterwards.
    static let probedPaths = [
        "",
        "Contents",
        "Contents/Resources",
        Command.dylibBinary,
        "Contents/MacOS",
        Command.defaultBinary,
        "Contents/_CodeSignature",
    ]

    static func inspect(app: URL, uid: uid_t = geteuid()) -> Report {
        var blockers = Set<Blocker>()
        var items: [Item] = []

        var fs = statfs()
        if statfs(app.path, &fs) == 0, fs.f_flags & UInt32(MNT_RDONLY) != 0 {
            blockers.insert(.readOnlyVolume)
        }

        for relative in probedPaths {
            let path = relative.isEmpty ? app.path : app.appendingPathComponent(relative).path
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR

            var flags: [String] = []
            if st.st_flags & UInt32(UF_IMMUTABLE) != 0 { flags.append("uchg") }
            if st.st_flags & UInt32(SF_IMMUTABLE) != 0 { flags.append("schg") }
            if st.st_flags & UInt32(UF_APPEND) != 0 { flags.append("uappnd") }
            if st.st_flags & UInt32(SF_APPEND) != 0 { flags.append("sappnd") }

            let deny = aclDeniesWrite(path: path, isDirectory: isDirectory)
            let posix = posixWritable(st, uid: uid)

            if !flags.isEmpty { blockers.insert(.immutable) }
            if deny { blockers.insert(.aclDeny) }
            if !posix { blockers.insert(.needsAdmin) }
            if !flags.isEmpty || deny || !posix {
                items.append(Item(path: path,
                                  owner: ownerName(st.st_uid),
                                  mode: String(st.st_mode & 0o7777, radix: 8),
                                  flags: flags,
                                  aclDeny: deny,
                                  posixWritable: posix))
            }
        }
        return Report(blockers: Blocker.allCases.filter(blockers.contains), items: items)
    }

    /// Human sentences for a report, one per blocker, each ending in the exact fix.
    static func advice(_ report: Report, app: URL) -> [String] {
        let quoted = Command.q(app.path)
        func paths(_ pick: (Item) -> Bool) -> String {
            report.items.filter(pick).map(\.path).joined(separator: ", ")
        }
        return report.blockers.map { blocker in
            switch blocker {
            case .readOnlyVolume:
                return "WeChat is on a read-only volume (opened from the disk image, or a translocated copy). Move WeChat.app into /Applications and patch that copy."
            case .immutable:
                let system = report.items.contains { $0.flags.contains("schg") || $0.flags.contains("sappnd") }
                let unlock = system ? "sudo chflags -R noschg,nosappnd,nouchg,nouappnd \(quoted)" : "chflags -R nouchg,nouappnd \(quoted)"
                return "Locked (immutable flag) on: \(paths { !$0.flags.isEmpty }). An administrator password does not bypass a lock. Unlock first: \(unlock)"
            case .aclDeny:
                return "An access-control entry denies writing on: \(paths { $0.aclDeny }). List it with `ls -led <path>` and remove the deny entry with `chmod -a# <index> <path>`."
            case .needsAdmin:
                let owners = Set(report.items.filter { !$0.posixWritable }.map(\.owner)).sorted().joined(separator: ", ")
                return "Owned by \(owners) without write access for this user: \(paths { !$0.posixWritable }). Run the patch with administrator rights (sudo)."
            case .appManagement:
                return "Owner, permission bits, lock flags and ACLs all allow this write, yet macOS refused it. That is most likely the App Management privacy permission: System Settings → Privacy & Security → App Management → enable the app that started this tool (WeChatUnrevoke, or your terminal), quit and reopen that app, then retry. An administrator password does not grant this permission. (Security software that protects apps can cause the same refusal.)"
            }
        }
    }

    /// Called after a write really failed. Returns nil when the error is not a permission
    /// refusal. When the filesystem shows nothing in the way, the refusal is attributed to
    /// App Management by elimination.
    static func explain(_ error: Swift.Error, app: URL) -> (report: Report, lines: [String])? {
        guard isPermissionFailure(error) else { return nil }
        var report = inspect(app: app)
        if report.blockers.isEmpty { report.blockers = [.appManagement] }
        return (report, advice(report, app: app))
    }

    /// The single line both humans and the GUI read: `Write blocked: <codes> — <fix>`.
    static func summaryLines(_ error: Swift.Error, app: URL) -> [String] {
        guard let (report, lines) = explain(error, app: app) else { return [] }
        return ["Write blocked: \(report.codes)"] + lines.map { "  " + $0 }
    }

    static func isPermissionFailure(_ error: Swift.Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 6 {
            if e.domain == NSPOSIXErrorDomain, [EPERM, EACCES, EROFS].contains(Int32(e.code)) { return true }
            if e.domain == NSCocoaErrorDomain,
               [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError, NSFileReadNoPermissionError].contains(e.code) {
                return true
            }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        let text = error.localizedDescription.lowercased()
        return ["operation not permitted", "permission denied", "read-only file system"].contains { text.contains($0) }
    }

    // MARK: - probes

    static func posixWritable(_ st: stat, uid: uid_t) -> Bool {
        if uid == 0 { return true }
        if st.st_uid == uid { return st.st_mode & S_IWUSR != 0 }
        if groups().contains(st.st_gid) { return st.st_mode & S_IWGRP != 0 }
        return st.st_mode & S_IWOTH != 0
    }

    private static func groups() -> [gid_t] {
        let count = getgroups(0, nil)
        guard count > 0 else { return [getegid()] }
        var list = [gid_t](repeating: 0, count: Int(count))
        let filled = getgroups(count, &list)
        return filled > 0 ? Array(list.prefix(Int(filled))) + [getegid()] : [getegid()]
    }

    private static func ownerName(_ uid: uid_t) -> String {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return "uid \(uid)" }
        return String(cString: name)
    }

    /// True when an extended ACL entry of type *deny* covers a write the patch needs:
    /// writing/appending a file, or adding/removing entries in a directory.
    static func aclDeniesWrite(path: String, isDirectory: Bool) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        // ACL_WRITE_DATA / ACL_APPEND_DATA share their bits with ACL_ADD_FILE / ACL_ADD_SUBDIRECTORY.
        let wanted: [acl_perm_t] = isDirectory
            ? [ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY, ACL_DELETE_CHILD]
            : [ACL_WRITE_DATA, ACL_APPEND_DATA]
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0, let e = entry {
            which = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(e, &tag) == 0, tag == ACL_EXTENDED_DENY else { continue }
            var permset: acl_permset_t?
            guard acl_get_permset(e, &permset) == 0, let p = permset else { continue }
            if wanted.contains(where: { acl_get_perm_np(p, $0) == 1 }) { return true }
        }
        return false
    }
}
